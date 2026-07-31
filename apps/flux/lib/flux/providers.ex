defmodule Flux.Providers do
  @moduledoc """
  Model-provider configuration per workspace: which plugins have credentials,
  and which models those unlock. Credentials are encrypted with the
  workspace DEK (`Flux.Crypto`); plaintext never touches the database.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Crypto
  alias Flux.Providers.ProviderCredential
  alias Flux.RBAC
  alias Flux.Repo

  # Resolved at call time so core never compile-depends on the runtime app
  # (dependency direction: plugin_runtime -> core), and tests can inject a
  # fake with Application.put_env(:flux, :plugin_runtime, Fake).
  defp runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

  @doc "All model-provider plugin manifests known to the runtime."
  def list_provider_plugins, do: runtime().list_model_providers()

  @doc "Credentials configured in the scope's workspace (config stays encrypted)."
  def list_credentials(%Scope{} = scope) do
    ProviderCredential
    |> Repo.scoped(scope)
    |> order_by([c], asc: c.plugin_id)
    |> Repo.all()
  end

  @doc """
  Saves (upserts) credentials for a plugin after validating them against the
  provider. Requires the `plugin_model_config` permission.
  """
  def upsert_credential(%Scope{} = scope, plugin_id, config) when is_map(config) do
    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         :ok <- validate_with_plugin(plugin_id, config),
         {:ok, encrypted} <- Crypto.encrypt(Scope.workspace_id(scope), Jason.encode!(config)) do
      %ProviderCredential{}
      |> ProviderCredential.changeset(%{
        workspace_id: Scope.workspace_id(scope),
        plugin_id: plugin_id,
        encrypted_config: encrypted,
        validated_at: DateTime.utc_now(:second)
      })
      |> Repo.insert(
        on_conflict: {:replace, [:encrypted_config, :validated_at, :updated_at]},
        conflict_target: [:workspace_id, :plugin_id, :name]
      )
    end
  end

  def delete_credential(%Scope{} = scope, credential_id) do
    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         %ProviderCredential{} = credential <-
           Repo.one(Repo.scoped(where(ProviderCredential, id: ^credential_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(credential)
    end
  end

  @doc "Decrypted credential config for a plugin, or `{:error, :not_configured}`."
  def fetch_config(workspace_id, plugin_id) do
    query =
      from(c in ProviderCredential,
        where: c.workspace_id == ^workspace_id and c.plugin_id == ^plugin_id
      )

    with %ProviderCredential{} = credential <- Repo.one(query) || {:error, :not_configured},
         {:ok, json} <- Crypto.decrypt(workspace_id, credential.encrypted_config) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  Models available to the workspace: every configured plugin's catalog, plus
  keyless plugins (empty credential schema, e.g. the Echo dev provider).
  """
  def available_models(%Scope{} = scope) do
    configured = MapSet.new(list_credentials(scope), & &1.plugin_id)

    for manifest <- list_provider_plugins(),
        manifest.credential_schema == [] or MapSet.member?(configured, manifest.id),
        {:ok, models} = runtime().models(manifest.id, %{}),
        model <- models do
      %{plugin_id: manifest.id, plugin_name: manifest.name, model: model}
    end
  end

  ## Default model (workspace-level system model)

  @doc """
  Sets the workspace default model, used by LLM/agent nodes whose config
  names no provider. Requires `plugin_model_config`. Pass empty strings
  to clear it.
  """
  def set_default_model(%Scope{} = scope, plugin_id, model) do
    with :ok <- RBAC.authorize(scope, :plugin_model_config) do
      workspace = Repo.get!(Flux.Accounts.Workspace, Scope.workspace_id(scope))

      default =
        if plugin_id in [nil, ""] or model in [nil, ""] do
          nil
        else
          %{"provider_plugin_id" => plugin_id, "model" => model}
        end

      custom_config =
        if default do
          Map.put(workspace.custom_config || %{}, "default_model", default)
        else
          Map.delete(workspace.custom_config || %{}, "default_model")
        end

      workspace
      |> Ecto.Changeset.change(custom_config: custom_config)
      |> Repo.update()
    end
  end

  @doc "The workspace default model as `%{\"provider_plugin_id\", \"model\"}` or nil."
  def default_model(%Scope{} = scope), do: default_model_for_workspace(Scope.workspace_id(scope))

  def default_model_for_workspace(nil), do: nil

  def default_model_for_workspace(workspace_id) do
    case Repo.get(Flux.Accounts.Workspace, workspace_id) do
      %{custom_config: %{"default_model" => %{} = default}} -> default
      _none -> nil
    end
  end

  defp validate_with_plugin(plugin_id, config) do
    case runtime().validate_credentials(plugin_id, config) do
      :ok -> :ok
      {:error, reason} when is_binary(reason) -> {:error, {:invalid_credentials, reason}}
      {:error, reason} -> {:error, {:invalid_credentials, inspect(reason)}}
    end
  end
end
