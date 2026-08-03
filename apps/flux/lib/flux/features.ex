defmodule Flux.Features do
  @moduledoc """
  The licensing/feature layer: a per-workspace plan maps to a feature
  set, and contexts call `authorize/2` at their gates. Self-hosted
  deployments default to `enterprise` — everything on — so gating is
  inert until an operator (or a future licensing backend) assigns a
  lower plan in workspace settings. The plan lives in the workspace's
  `custom_config`, exactly where a license validator would write it.
  """

  alias Flux.Accounts.Scope
  alias Flux.Accounts.Workspace
  alias Flux.Repo

  @features ~w(custom_roles annotations datasource_sync scim llm_entity_extraction)a

  @plans %{
    "free" => MapSet.new([]),
    "team" => MapSet.new(~w(annotations datasource_sync)a),
    "enterprise" => MapSet.new(@features)
  }

  @default_plan "enterprise"

  def plans, do: Map.keys(@plans)
  def features, do: @features

  @doc "The workspace's plan name (default #{@default_plan})."
  def plan(%Scope{} = scope), do: plan_for_workspace(Scope.workspace_id(scope))

  def plan_for_workspace(workspace_id) do
    case workspace_id && Repo.get(Workspace, workspace_id) do
      %{custom_config: %{"plan" => plan}} when is_map_key(@plans, plan) -> plan
      _default -> @default_plan
    end
  end

  def enabled?(%Scope{} = scope, feature) when feature in @features do
    enabled_for_workspace?(Scope.workspace_id(scope), feature)
  end

  @doc "Scope-less check for background workers that only hold a workspace id."
  def enabled_for_workspace?(workspace_id, feature) when feature in @features do
    MapSet.member?(Map.fetch!(@plans, plan_for_workspace(workspace_id)), feature)
  end

  @doc "Gate check for `with` chains: `:ok | {:error, :feature_disabled}`."
  def authorize(%Scope{} = scope, feature) do
    if enabled?(scope, feature), do: :ok, else: {:error, :feature_disabled}
  end

  @doc "Owner-only plan assignment (the stand-in for a license validator)."
  def set_plan(%Scope{} = scope, plan) when is_map_key(@plans, plan) do
    with true <- Scope.role(scope) == :owner || {:error, :unauthorized},
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)),
         {:ok, updated} <-
           workspace
           |> Ecto.Changeset.change(
             custom_config: Map.put(workspace.custom_config || %{}, "plan", plan)
           )
           |> Repo.update() do
      Flux.Audit.record(scope, "workspace.plan_set",
        resource_type: "workspace",
        resource_id: workspace.id,
        metadata: %{"plan" => plan}
      )

      {:ok, updated}
    end
  end

  def set_plan(%Scope{}, _unknown_plan), do: {:error, :unknown_plan}

  @doc "Instance-admin plan change (no workspace scope; the admin panel)."
  def set_plan_for_workspace(workspace_id, plan) when is_map_key(@plans, plan) do
    with %Workspace{} = workspace <- Repo.get(Workspace, workspace_id) do
      workspace
      |> Ecto.Changeset.change(
        custom_config: Map.put(workspace.custom_config || %{}, "plan", plan)
      )
      |> Repo.update()
    end
  end

  def set_plan_for_workspace(_workspace_id, _unknown_plan), do: {:error, :unknown_plan}
end
