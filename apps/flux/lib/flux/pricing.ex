defmodule Flux.Pricing do
  @moduledoc """
  Estimated USD cost for model token usage. Prices are per **million**
  tokens `{input, output}`, matched by longest model-id prefix so dated
  snapshots ("claude-sonnet-5-20260203") resolve to their family row.

  The table is a best-effort estimate baked in at release time — real
  invoices come from your provider. Override or extend per deployment:

      config :flux, :model_pricing, %{"my-finetune" => {2.0, 8.0}}
  """

  @defaults %{
    # Anthropic
    "claude-fable-5" => {10.0, 50.0},
    "claude-mythos-5" => {10.0, 50.0},
    "claude-opus-5" => {5.0, 25.0},
    "claude-opus-4" => {15.0, 75.0},
    "claude-opus-4-5" => {5.0, 25.0},
    "claude-opus-4-6" => {5.0, 25.0},
    "claude-opus-4-7" => {5.0, 25.0},
    "claude-opus-4-8" => {5.0, 25.0},
    "claude-sonnet-5" => {3.0, 15.0},
    "claude-sonnet-4" => {3.0, 15.0},
    "claude-3-7-sonnet" => {3.0, 15.0},
    "claude-3-5-sonnet" => {3.0, 15.0},
    "claude-haiku-4-5" => {1.0, 5.0},
    "claude-3-5-haiku" => {0.8, 4.0},
    "claude-3-haiku" => {0.25, 1.25},
    # OpenAI
    "gpt-5-nano" => {0.05, 0.4},
    "gpt-5-mini" => {0.25, 2.0},
    "gpt-5" => {1.25, 10.0},
    "gpt-4o-mini" => {0.15, 0.6},
    "gpt-4o" => {2.5, 10.0},
    "gpt-4.1-nano" => {0.1, 0.4},
    "gpt-4.1-mini" => {0.4, 1.6},
    "gpt-4.1" => {2.0, 8.0},
    "o4-mini" => {1.1, 4.4},
    "o3" => {2.0, 8.0},
    # Google
    "gemini-2.5-pro" => {1.25, 10.0},
    "gemini-2.5-flash-lite" => {0.1, 0.4},
    "gemini-2.5-flash" => {0.3, 2.5},
    "gemini-2.0-flash" => {0.1, 0.4}
  }

  @doc """
  Estimated cost in USD for one model's tokens, or `:unknown` when the
  model has no pricing row. Pass a workspace id first to apply that
  workspace's overrides (self-hosted and fine-tuned models the built-in
  table can't know).
  """
  def estimate(model, input_tokens, output_tokens)
      when is_binary(model) and is_integer(input_tokens) and is_integer(output_tokens) do
    estimate(nil, model, input_tokens, output_tokens)
  end

  def estimate(workspace_id, model, input_tokens, output_tokens)
      when is_binary(model) and is_integer(input_tokens) and is_integer(output_tokens) do
    case lookup(model, workspace_overrides(workspace_id)) do
      {input_per_m, output_per_m} ->
        {:ok, input_tokens / 1_000_000 * input_per_m + output_tokens / 1_000_000 * output_per_m}

      nil ->
        :unknown
    end
  end

  @doc """
  Total estimated cost for a `%{model => %{"input_tokens" => n, "output_tokens" => n}}`
  breakdown. Returns `nil` when none of the models are priced (so callers
  can distinguish "free" from "no idea"). Workspace-id variant applies
  that workspace's overrides.
  """
  def cost_for(by_model) when is_map(by_model), do: cost_for(nil, by_model)

  def cost_for(workspace_id, by_model) when is_map(by_model) do
    costs =
      for {model, usage} <- by_model,
          {:ok, cost} <-
            [
              estimate(
                workspace_id,
                model,
                usage["input_tokens"] || 0,
                usage["output_tokens"] || 0
              )
            ] do
        cost
      end

    case costs do
      [] -> nil
      costs -> Float.round(Enum.sum(costs), 6)
    end
  end

  @doc """
  Saves workspace price overrides from text lines of
  `model-prefix input-per-million output-per-million` (blank clears).
  """
  def configure_overrides(%Flux.Accounts.Scope{} = scope, text) do
    lines =
      text
      |> to_string()
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.split(String.trim(&1)))
      |> Enum.reject(&(&1 == []))

    parsed =
      Enum.reduce_while(lines, %{}, fn
        [model, input, output], acc ->
          with {input_per_m, ""} <- Float.parse(input),
               {output_per_m, ""} <- Float.parse(output) do
            {:cont, Map.put(acc, model, [input_per_m, output_per_m])}
          else
            _bad -> {:halt, {:error, Enum.join([model, input, output], " ")}}
          end

        bad_line, _acc ->
          {:halt, {:error, Enum.join(bad_line, " ")}}
      end)

    case parsed do
      {:error, line} -> {:error, {:invalid_line, line}}
      overrides when overrides == %{} -> put_overrides(scope, nil)
      overrides -> put_overrides(scope, overrides)
    end
  end

  @doc "The workspace's saved overrides as `%{prefix => [input, output]}`."
  def overrides(workspace_id) do
    case Flux.Repo.get(Flux.Accounts.Workspace, workspace_id) do
      %{custom_config: %{"model_pricing" => %{} = overrides}} -> overrides
      _none -> %{}
    end
  end

  defp put_overrides(scope, value) do
    with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
         %Flux.Accounts.Workspace{} = workspace <-
           Flux.Repo.get(Flux.Accounts.Workspace, Flux.Accounts.Scope.workspace_id(scope)) do
      custom_config =
        if value == nil do
          Map.delete(workspace.custom_config || %{}, "model_pricing")
        else
          Map.put(workspace.custom_config || %{}, "model_pricing", value)
        end

      workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Flux.Repo.update()
    end
  end

  defp workspace_overrides(nil), do: %{}

  defp workspace_overrides(workspace_id) do
    Map.new(overrides(workspace_id), fn
      {prefix, [input, output]} -> {prefix, {input * 1.0, output * 1.0}}
      {prefix, {input, output}} -> {prefix, {input, output}}
    end)
  end

  defp lookup(model, workspace_table) do
    table =
      @defaults
      |> Map.merge(Application.get_env(:flux, :model_pricing, %{}))
      |> Map.merge(workspace_table)

    table
    |> Enum.filter(fn {prefix, _price} -> String.starts_with?(model, prefix) end)
    |> Enum.max_by(fn {prefix, _price} -> byte_size(prefix) end, fn -> nil end)
    |> case do
      {_prefix, price} -> price
      nil -> nil
    end
  end
end
