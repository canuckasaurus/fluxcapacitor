defmodule Flux.Guardrails do
  @moduledoc """
  Workspace guardrails: deny patterns (case-insensitive regex, one per
  line in settings) checked against run/chat inputs and outputs. The
  configured action decides input handling — `block` refuses with an
  honest error, `flag` lets it through — and every violation lands a
  `guardrail` notification (routable to webhooks like any other kind).
  Outputs are always flag-only: the tokens are already spent, so the
  team gets told rather than the user getting a hole in the reply.
  """

  alias Flux.Accounts.Scope
  alias Flux.Accounts.Workspace
  alias Flux.Repo

  @doc "The workspace's guardrail config: `%{patterns: [...], action: \"block\"|\"flag\"}`."
  def config(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %{custom_config: %{"guardrails" => %{"patterns" => patterns} = config}}
      when is_list(patterns) and patterns != [] ->
        %{patterns: patterns, action: config["action"] || "block"}

      _off ->
        nil
    end
  end

  @doc "Saves patterns (newline-separated; blank disables) and the action."
  def configure(%Scope{} = scope, patterns_text, action) when action in ["block", "flag"] do
    patterns =
      patterns_text
      |> to_string()
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    invalid = Enum.find(patterns, &match?({:error, _reason}, Regex.compile(&1, "i")))

    cond do
      invalid != nil ->
        {:error, {:invalid_pattern, invalid}}

      patterns == [] ->
        update(scope, nil)

      true ->
        update(scope, %{"patterns" => patterns, "action" => action})
    end
  end

  defp update(scope, value) do
    with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      custom_config =
        if value == nil do
          Map.delete(workspace.custom_config || %{}, "guardrails")
        else
          Map.put(workspace.custom_config || %{}, "guardrails", value)
        end

      workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update()
    end
  end

  @doc "First matching pattern in the text, or nil."
  def violation(workspace_id, text) when is_binary(text) do
    case config(workspace_id) do
      nil ->
        nil

      %{patterns: patterns} ->
        Enum.find(patterns, fn pattern ->
          case Regex.compile(pattern, "i") do
            {:ok, regex} -> Regex.match?(regex, text)
            {:error, _reason} -> false
          end
        end)
    end
  end

  def violation(_workspace_id, _text), do: nil

  @doc """
  Input gate: `:ok`, or `{:error, :guardrail}` when a pattern matches
  and the action is block. Either way a violation notifies the team.
  """
  def check_input(workspace_id, text, context \\ "input") do
    case violation(workspace_id, text) do
      nil ->
        :ok

      pattern ->
        notify(workspace_id, pattern, context)

        case config(workspace_id) do
          %{action: "flag"} -> :ok
          _block -> {:error, :guardrail}
        end
    end
  end

  @doc "Output check: never blocks, always notifies on a match."
  def flag_output(workspace_id, text, context \\ "output") do
    case violation(workspace_id, text) do
      nil -> :ok
      pattern -> notify(workspace_id, pattern, context)
    end
  end

  defp notify(workspace_id, pattern, context) do
    Flux.Notifications.notify(
      workspace_id,
      "guardrail",
      "Guardrail matched on #{context}: pattern #{inspect(pattern)}",
      "/console/settings"
    )
  end
end
