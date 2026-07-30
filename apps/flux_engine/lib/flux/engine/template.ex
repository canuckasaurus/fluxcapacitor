defmodule Flux.Engine.Template do
  @moduledoc """
  `{{node_id.path}}` interpolation against the run's variable pool.

  The pool maps node ids to their output maps (string keys). Dotted paths
  descend into nested maps; unresolved references render as `""` so a typo
  degrades to blank output instead of crashing a run.
  """

  @reference ~r/\{\{\s*([\w-]+(?:\.[\w-]+)*)\s*\}\}/

  @doc "Renders every `{{reference}}` in the template from the pool."
  @spec render(String.t() | nil, map()) :: String.t()
  def render(nil, _pool), do: ""

  def render(template, pool) when is_binary(template) do
    Regex.replace(@reference, template, fn _whole, path ->
      pool |> resolve(path) |> to_text()
    end)
  end

  @doc "Resolves a dotted path (`\"llm_1.text\"`) in the pool; nil if absent."
  @spec resolve(map(), String.t()) :: term()
  def resolve(pool, path) do
    path
    |> String.split(".")
    |> Enum.reduce(pool, fn
      key, %{} = acc -> Map.get(acc, key)
      _key, _acc -> nil
    end)
  end

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp to_text(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value)
    end
  end

  defp to_text(value), do: inspect(value)
end
