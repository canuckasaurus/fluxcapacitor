defmodule Flux.SafeRegex do
  @moduledoc """
  Regex matching with a bounded backtracking budget.

  User-authored patterns — workspace/app guardrails, the eval regex
  grader, interview answer validators — run against attacker-influenced
  text on hot paths (every chat and workflow-run input passes the
  guardrail check). A catastrophic pattern like `(a+)+$` fed a modest
  input would otherwise pin a BEAM scheduler for seconds, a
  workspace-wide denial of service.

  PCRE's `match_limit`/`match_limit_recursion` cap the number of
  backtracking steps regardless of the pattern's shape: a match that
  blows the budget is reported as a non-match (and a replace leaves the
  text untouched at that position) rather than running unbounded. The
  subject is also clamped to `@max_bytes` first, so a huge input can't
  amplify a merely-expensive pattern.

  Patterns still compile through `Regex`, so callers keep the same
  compile-time validation and the `"i"` (caseless) flag they had before.
  """

  # ~100k backtracking steps is generous for legitimate patterns yet
  # completes in well under a millisecond even when exhausted.
  @match_limit 100_000
  @recursion_limit 10_000
  @max_bytes 200_000

  @doc "Compiles a user pattern (caseless by default); mirrors `Regex.compile/2`."
  @spec compile(String.t(), binary()) :: {:ok, Regex.t()} | {:error, term()}
  def compile(pattern, options \\ "i"), do: Regex.compile(pattern, options)

  @doc """
  `true` when `regex` matches `text` within the backtracking budget.
  A pattern that exhausts the budget (or anything but a binary subject)
  is treated as no match.
  """
  @spec match?(Regex.t(), term()) :: boolean()
  def match?(%Regex{} = regex, text) when is_binary(text) do
    case :re.run(clamp(text), Regex.re_pattern(regex), run_opts()) do
      {:match, _captures} -> true
      _nomatch_or_over_budget -> false
    end
  end

  def match?(_regex, _text), do: false

  @doc """
  Replaces every match of `regex` in `text` with `replacement`, within
  the backtracking budget. Over-budget positions are left as-is.
  """
  @spec replace(Regex.t(), String.t(), iodata()) :: String.t()
  def replace(%Regex{} = regex, text, replacement) when is_binary(text) do
    :re.replace(
      clamp(text),
      Regex.re_pattern(regex),
      replacement,
      [:global, {:return, :binary}] ++ run_opts()
    )
  end

  def replace(_regex, text, _replacement), do: to_string(text)

  defp run_opts,
    do: [{:match_limit, @match_limit}, {:match_limit_recursion, @recursion_limit}]

  defp clamp(text) when byte_size(text) > @max_bytes, do: binary_part(text, 0, @max_bytes)
  defp clamp(text), do: text
end
