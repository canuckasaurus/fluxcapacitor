defmodule Flux.Plugins.Utility do
  @moduledoc """
  Built-in tool plugin: small deterministic utilities that need no
  credentials — current time and a safe arithmetic calculator.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.Tool

  alias Flux.Plugin.Manifest
  alias Flux.Plugin.Tool.Operation

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "utility",
      name: "Utilities",
      version: "0.1.0",
      category: :tool,
      description: "Current time and a safe calculator — no credentials needed.",
      credential_schema: []
    }
  end

  @impl Flux.Plugin.Tool
  def operations(_credentials) do
    [
      %Operation{
        id: "current_time",
        name: "current_time",
        description: "The current UTC date and time (ISO 8601).",
        parameters: %{"type" => "object", "properties" => %{}}
      },
      %Operation{
        id: "calculate",
        name: "calculate",
        description: "Evaluate an arithmetic expression (+, -, *, /, parentheses).",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "expression" => %{"type" => "string", "description" => "e.g. (2 + 3) * 4.5"}
          },
          "required" => ["expression"]
        }
      }
    ]
  end

  @impl Flux.Plugin.Tool
  def invoke(_credentials, "current_time", _args) do
    now = DateTime.utc_now(:second)
    {:ok, %{text: DateTime.to_iso8601(now), data: %{"iso8601" => DateTime.to_iso8601(now)}}}
  end

  def invoke(_credentials, "calculate", %{"expression" => expression}) do
    case Flux.Plugins.Utility.Calculator.eval(expression) do
      {:ok, value} -> {:ok, %{text: format_number(value), data: %{"result" => value}}}
      {:error, message} -> {:error, message}
    end
  end

  def invoke(_credentials, operation, _args), do: {:error, "unknown operation #{operation}"}

  defp format_number(value) when is_float(value) do
    if Float.round(value) == value and abs(value) < 1.0e15 do
      value |> trunc() |> Integer.to_string()
    else
      Float.to_string(value)
    end
  end

  defp format_number(value), do: to_string(value)
end

defmodule Flux.Plugins.Utility.Calculator do
  @moduledoc false
  # Recursive-descent parser for + - * / and parentheses. No code
  # evaluation, no function calls — strictly arithmetic.

  def eval(expression) when is_binary(expression) do
    with {:ok, tokens} <- tokenize(expression, []),
         {:ok, value, []} <- expr(tokens) do
      {:ok, value * 1.0}
    else
      {:ok, _value, _leftover} -> {:error, "unexpected trailing input"}
      {:error, message} -> {:error, message}
    end
  end

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<c, rest::binary>>, acc) when c in ~c[ \t], do: tokenize(rest, acc)

  defp tokenize(<<c, rest::binary>>, acc) when c in ~c[+*/()-],
    do: tokenize(rest, [<<c>> | acc])

  defp tokenize(binary, acc) do
    case Float.parse(binary) do
      {number, rest} -> tokenize(rest, [number | acc])
      :error -> {:error, "unexpected input at #{inspect(String.slice(binary, 0, 10))}"}
    end
  end

  defp expr(tokens) do
    with {:ok, left, rest} <- term(tokens), do: expr_tail(left, rest)
  end

  defp expr_tail(left, [op | rest]) when op in ["+", "-"] do
    with {:ok, right, rest} <- term(rest) do
      expr_tail((op == "+" && left + right) || left - right, rest)
    end
  end

  defp expr_tail(left, rest), do: {:ok, left, rest}

  defp term(tokens) do
    with {:ok, left, rest} <- factor(tokens), do: term_tail(left, rest)
  end

  defp term_tail(left, [op | rest]) when op in ["*", "/"] do
    with {:ok, right, rest} <- factor(rest) do
      cond do
        op == "*" -> term_tail(left * right, rest)
        right == 0 -> {:error, "division by zero"}
        true -> term_tail(left / right, rest)
      end
    end
  end

  defp term_tail(left, rest), do: {:ok, left, rest}

  defp factor([number | rest]) when is_number(number), do: {:ok, number, rest}

  defp factor(["-" | rest]) do
    with {:ok, value, rest} <- factor(rest), do: {:ok, -value, rest}
  end

  defp factor(["(" | rest]) do
    with {:ok, value, [")" | rest]} <- expr(rest) do
      {:ok, value, rest}
    else
      {:ok, _value, _no_paren} -> {:error, "missing closing parenthesis"}
      error -> error
    end
  end

  defp factor(_tokens), do: {:error, "expected a number"}
end
