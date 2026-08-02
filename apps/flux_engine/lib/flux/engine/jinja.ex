defmodule Flux.Engine.Jinja do
  @moduledoc """
  A pure-Elixir Jinja subset for template nodes and doc templates — no
  code execution, deterministic, dependency-free. Supported:

    * `{{ path.to.value }}` with chained filters:
      `{{ name | trim | upper }}`, `{{ items | join(", ") }}`,
      `{{ missing | default("n/a") }}`, plus `lower`, `capitalize`,
      `length`, `first`, `last`, `truncate(n)`, `replace(a, b)`,
      `round(n)`, `json`
    * `{% if expr %} … {% elif expr %} … {% else %} … {% endif %}` —
      comparisons (`==`, `!=`, `>`, `>=`, `<`, `<=`), `not`, `and`/`or`
      (left-associative), truthiness of bare paths
    * `{% for item in path %} … {% endfor %}` with `loop.index`,
      `loop.index0`, `loop.first`, `loop.last`; nests
    * `{# comments #}` (stripped)

  Undefined variables render as `""` (matching the simple engine);
  malformed templates return `{:error, message}` so a node fails loudly
  instead of emitting garbage.
  """

  alias Flux.Engine.Template

  @token ~r/(\{\{.*?\}\}|\{%.*?%\}|\{#.*?#\})/s

  @spec render(String.t() | nil, map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def render(template, context, opts \\ [])

  def render(nil, _context, _opts), do: {:ok, ""}

  def render(template, context, opts) when is_binary(template) do
    escape = Keyword.get(opts, :escape, & &1)

    with {:ok, ast, []} <- template |> tokenize() |> parse_block([]) do
      {:ok, render_ast(ast, context, escape)}
    else
      {:ok, _ast, [token | _rest]} -> {:error, "unexpected #{describe(token)}"}
      {:error, message} -> {:error, message}
    end
  rescue
    exception -> {:error, "template error: " <> Exception.message(exception)}
  end

  ## Tokenizer

  defp tokenize(template) do
    @token
    |> Regex.split(template, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn
      "{{" <> rest -> [{:expr, rest |> String.trim_trailing("}}") |> String.trim()}]
      "{#" <> _comment -> []
      "{%" <> rest -> [tag(rest |> String.trim_trailing("%}") |> String.trim())]
      text -> [{:text, text}]
    end)
  end

  defp tag("if " <> expr), do: {:if, String.trim(expr)}
  defp tag("elif " <> expr), do: {:elif, String.trim(expr)}
  defp tag("else"), do: :else
  defp tag("endif"), do: :endif
  defp tag("endfor"), do: :endfor

  defp tag("for " <> rest) do
    case Regex.run(~r/^([A-Za-z_][\w]*)\s+in\s+(.+)$/, String.trim(rest)) do
      [_whole, var, source] -> {:for, var, String.trim(source)}
      nil -> {:bad_tag, "for " <> rest}
    end
  end

  defp tag(other), do: {:bad_tag, other}

  ## Parser — returns {:ok, nodes, remaining_tokens}

  defp parse_block([], acc), do: {:ok, Enum.reverse(acc), []}

  defp parse_block([{:text, text} | rest], acc), do: parse_block(rest, [{:text, text} | acc])
  defp parse_block([{:expr, expr} | rest], acc), do: parse_block(rest, [{:output, expr} | acc])

  defp parse_block([{:if, expr} | rest], acc) do
    with {:ok, branches, rest} <- parse_if(rest, expr) do
      parse_block(rest, [{:cond, branches} | acc])
    end
  end

  defp parse_block([{:for, var, source} | rest], acc) do
    with {:ok, body, rest} <- parse_until(rest, :endfor) do
      parse_block(rest, [{:for, var, source, body} | acc])
    end
  end

  defp parse_block([{:bad_tag, tag} | _rest], _acc),
    do: {:error, "unknown tag {% #{tag} %}"}

  # Closers surface to the caller (parse_until / parse_if handle them).
  defp parse_block([closer | _rest] = tokens, acc)
       when closer in [:endif, :endfor, :else] or
              (is_tuple(closer) and elem(closer, 0) == :elif) do
    {:ok, Enum.reverse(acc), tokens}
  end

  # {branches :: [{condition_expr | :else, body}]}
  defp parse_if(tokens, condition) do
    with {:ok, body, rest} <- parse_branch_body(tokens) do
      case rest do
        [{:elif, next_condition} | rest] ->
          with {:ok, branches, rest} <- parse_if(rest, next_condition) do
            {:ok, [{condition, body} | branches], rest}
          end

        [:else | rest] ->
          with {:ok, else_body, rest} <- parse_branch_body(rest),
               [:endif | rest] <- rest do
            {:ok, [{condition, body}, {:else, else_body}], rest}
          else
            {:error, message} -> {:error, message}
            _missing -> {:error, "missing {% endif %}"}
          end

        [:endif | rest] ->
          {:ok, [{condition, body}], rest}

        _other ->
          {:error, "missing {% endif %}"}
      end
    end
  end

  defp parse_branch_body(tokens), do: parse_block(tokens, [])

  defp parse_until(tokens, closer) do
    case parse_block(tokens, []) do
      {:ok, body, [^closer | rest]} -> {:ok, body, rest}
      {:ok, _body, _other} -> {:error, "missing {% #{closer} %}"}
      {:error, message} -> {:error, message}
    end
  end

  ## Renderer

  # `escape` applies to interpolated output values only — literal
  # template text passes through untouched (the DOCX renderer relies on
  # this: the literals are the document's own XML).
  defp render_ast(nodes, context, escape) do
    Enum.map_join(nodes, "", &render_node(&1, context, escape))
  end

  defp render_node({:text, text}, _context, _escape), do: text

  defp render_node({:output, expr}, context, escape) do
    expr |> eval_pipeline(context) |> to_text() |> escape.()
  end

  defp render_node({:cond, branches}, context, escape) do
    branches
    |> Enum.find(fn
      {:else, _body} -> true
      {condition, _body} -> truthy?(eval_condition(condition, context))
    end)
    |> case do
      {_condition, body} -> render_ast(body, context, escape)
      nil -> ""
    end
  end

  defp render_node({:for, var, source, body}, context, escape) do
    items = source |> eval_pipeline(context) |> as_list()
    total = length(items)

    items
    |> Enum.with_index(1)
    |> Enum.map_join("", fn {item, index} ->
      loop = %{
        "index" => index,
        "index0" => index - 1,
        "first" => index == 1,
        "last" => index == total
      }

      render_ast(body, context |> Map.put(var, item) |> Map.put("loop", loop), escape)
    end)
  end

  defp as_list(list) when is_list(list), do: list
  defp as_list(%{} = map), do: Map.to_list(map)

  defp as_list(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, list} when is_list(list) -> list
      _not_a_list -> []
    end
  end

  defp as_list(_other), do: []

  ## Expressions: value [| filter[(args)]]*

  defp eval_pipeline(expr, context) do
    [value_expr | filters] = split_pipeline(expr)

    Enum.reduce(filters, eval_value(String.trim(value_expr), context), fn filter, acc ->
      apply_filter(acc, String.trim(filter))
    end)
  end

  # Split on | outside of quotes.
  defp split_pipeline(expr) do
    expr
    |> String.graphemes()
    |> Enum.reduce({[], "", nil}, fn char, {parts, current, quote} ->
      cond do
        char in ["\"", "'"] and quote == nil -> {parts, current <> char, char}
        char == quote -> {parts, current <> char, nil}
        char == "|" and quote == nil -> {[current | parts], "", nil}
        true -> {parts, current <> char, quote}
      end
    end)
    |> then(fn {parts, current, _quote} -> Enum.reverse([current | parts]) end)
  end

  defp eval_value(expr, context) do
    cond do
      expr == "" -> nil
      expr in ["true", "True"] -> true
      expr in ["false", "False"] -> false
      Regex.match?(~r/^-?\d+$/, expr) -> String.to_integer(expr)
      Regex.match?(~r/^-?\d+\.\d+$/, expr) -> String.to_float(expr)
      quoted?(expr) -> String.slice(expr, 1..-2//1)
      true -> Template.resolve(context, expr)
    end
  end

  defp quoted?(expr) do
    (String.starts_with?(expr, "\"") and String.ends_with?(expr, "\"")) or
      (String.starts_with?(expr, "'") and String.ends_with?(expr, "'"))
  end

  ## Filters

  defp apply_filter(value, filter) do
    case Regex.run(~r/^([a-z_]+)(?:\((.*)\))?$/s, filter) do
      [_whole, name] -> run_filter(name, value, [])
      [_whole, name, args] -> run_filter(name, value, parse_args(args))
      nil -> value
    end
  end

  defp parse_args(args) do
    args
    |> split_top_level_commas()
    |> Enum.map(&eval_value(String.trim(&1), %{}))
  end

  defp split_top_level_commas(text) do
    text
    |> String.graphemes()
    |> Enum.reduce({[], "", nil}, fn char, {parts, current, quote} ->
      cond do
        char in ["\"", "'"] and quote == nil -> {parts, current <> char, char}
        char == quote -> {parts, current <> char, nil}
        char == "," and quote == nil -> {[current | parts], "", nil}
        true -> {parts, current <> char, quote}
      end
    end)
    |> then(fn {parts, current, _quote} -> Enum.reverse([current | parts]) end)
  end

  defp run_filter("upper", value, _args), do: value |> to_text() |> String.upcase()
  defp run_filter("lower", value, _args), do: value |> to_text() |> String.downcase()
  defp run_filter("trim", value, _args), do: value |> to_text() |> String.trim()
  defp run_filter("capitalize", value, _args), do: value |> to_text() |> String.capitalize()
  defp run_filter("length", value, _args) when is_list(value), do: length(value)
  defp run_filter("length", %{} = value, _args), do: map_size(value)
  defp run_filter("length", value, _args), do: value |> to_text() |> String.length()
  defp run_filter("first", value, _args) when is_list(value), do: List.first(value)
  defp run_filter("first", value, _args), do: value |> to_text() |> String.first()
  defp run_filter("last", value, _args) when is_list(value), do: List.last(value)
  defp run_filter("last", value, _args), do: value |> to_text() |> String.last()

  defp run_filter("default", value, [fallback | _rest]) do
    if value in [nil, ""], do: fallback, else: value
  end

  defp run_filter("join", value, args) when is_list(value) do
    separator = to_text(List.first(args) || "")
    Enum.map_join(value, separator, &to_text/1)
  end

  defp run_filter("truncate", value, [limit | _rest]) when is_integer(limit) do
    text = to_text(value)
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "…"
  end

  defp run_filter("replace", value, [from, to | _rest]) do
    value |> to_text() |> String.replace(to_text(from), to_text(to))
  end

  defp run_filter("round", value, args) when is_number(value) do
    digits = (is_integer(List.first(args)) && List.first(args)) || 0
    Float.round(value * 1.0, digits)
  end

  defp run_filter("json", value, _args) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value)
    end
  end

  defp run_filter(_unknown, value, _args), do: value

  ## Conditions: `not`? value [op value], joined by and/or (left-assoc)

  defp eval_condition(expr, context) do
    expr
    |> split_logical()
    |> Enum.reduce(nil, fn
      {:first, clause}, nil -> eval_clause(clause, context)
      {:and, clause}, acc -> acc && eval_clause(clause, context)
      {:or, clause}, acc -> acc || eval_clause(clause, context)
    end)
  end

  defp split_logical(expr) do
    parts = Regex.split(~r/\s+(and|or)\s+/, expr, include_captures: true)

    case parts do
      [first | rest] ->
        [{:first, first} | pair_up(rest)]
    end
  end

  defp pair_up([]), do: []

  defp pair_up([op, clause | rest]),
    do: [{String.to_atom(String.trim(op)), clause} | pair_up(rest)]

  defp eval_clause(clause, context) do
    clause = String.trim(clause)

    case clause do
      "not " <> negated -> not truthy?(eval_clause(negated, context))
      _plain -> eval_comparison(clause, context)
    end
  end

  @operators ["==", "!=", ">=", "<=", ">", "<"]

  defp eval_comparison(clause, context) do
    case Regex.run(~r/^(.+?)\s*(==|!=|>=|<=|>|<)\s*(.+)$/, clause) do
      [_whole, left, operator, right] when operator in @operators ->
        compare(eval_pipeline(left, context), operator, eval_pipeline(right, context))

      nil ->
        truthy?(eval_pipeline(clause, context))
    end
  end

  defp compare(left, "==", right), do: loose(left) == loose(right)
  defp compare(left, "!=", right), do: loose(left) != loose(right)

  defp compare(left, operator, right) do
    with {:ok, l} <- to_number(left), {:ok, r} <- to_number(right) do
      case operator do
        ">" -> l > r
        ">=" -> l >= r
        "<" -> l < r
        "<=" -> l <= r
      end
    else
      _not_numeric -> false
    end
  end

  # Numbers compare loosely with their string forms ("3" == 3).
  defp loose(value) when is_number(value), do: to_text(value)
  defp loose(value), do: value

  defp to_number(value) when is_number(value), do: {:ok, value}

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _invalid -> :error
    end
  end

  defp to_number(_value), do: :error

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(""), do: false
  defp truthy?([]), do: false
  defp truthy?(map) when map == %{}, do: false
  defp truthy?(0), do: false
  defp truthy?(_value), do: true

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_float(value), do: to_string(value)
  defp to_text(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp to_text(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value)
    end
  end

  defp to_text(value), do: inspect(value)

  defp describe(:endif), do: "{% endif %}"
  defp describe(:endfor), do: "{% endfor %}"
  defp describe(:else), do: "{% else %}"
  defp describe({:elif, _expr}), do: "{% elif %}"
  defp describe(other), do: inspect(other)
end
