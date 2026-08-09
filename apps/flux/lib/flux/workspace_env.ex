defmodule Flux.WorkspaceEnv do
  @moduledoc """
  Workspace-wide environment variables: one encrypted store reachable as
  `{{env.NAME}}` from every flux (prompts, HTTP nodes, code inputs) —
  API keys and shared config live once instead of per-flux. A flux's own
  graph `env` wins on name collisions. Secret-flagged values never
  render back in the settings UI.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Crypto
  alias Flux.RBAC
  alias Flux.Repo

  @name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  defmodule EnvVar do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "workspace_env_vars" do
      belongs_to :workspace, Flux.Accounts.Workspace

      field :name, :string
      field :encrypted_value, :binary
      field :is_secret, :boolean, default: false

      timestamps(type: :utc_datetime)
    end
  end

  @doc """
  Rows for the settings page: `%{name, value, is_secret}` — secret
  values come back as `nil` (write-only).
  """
  def list(%Scope{} = scope) do
    workspace_id = Scope.workspace_id(scope)

    EnvVar
    |> Repo.scoped(scope)
    |> order_by([v], asc: v.name)
    |> Repo.all()
    |> Enum.map(fn var ->
      %{
        name: var.name,
        is_secret: var.is_secret,
        value: if(var.is_secret, do: nil, else: decrypt_value(workspace_id, var))
      }
    end)
  end

  @doc "Creates or replaces a variable. Blank values are refused."
  def put(%Scope{} = scope, name, value, is_secret \\ false) do
    workspace_id = Scope.workspace_id(scope)
    name = String.trim(to_string(name))
    value = value |> to_string() |> String.trim()

    with :ok <- RBAC.authorize(scope, :credential_manage),
         true <- Regex.match?(@name_pattern, name) || {:error, :bad_name},
         true <- value != "" || {:error, :blank_value},
         {:ok, encrypted} <- Crypto.encrypt(workspace_id, value) do
      Repo.insert!(
        %EnvVar{
          workspace_id: workspace_id,
          name: name,
          encrypted_value: encrypted,
          is_secret: is_secret
        },
        on_conflict: {:replace, [:encrypted_value, :is_secret, :updated_at]},
        conflict_target: [:workspace_id, :name]
      )

      Flux.Audit.record(scope, "workspace.env_var_put",
        resource_type: "workspace_env_var",
        resource_id: name,
        metadata: %{"secret" => is_secret}
      )

      :ok
    end
  end

  def delete(%Scope{} = scope, name) do
    with :ok <- RBAC.authorize(scope, :credential_manage) do
      EnvVar
      |> Repo.scoped(scope)
      |> where([v], v.name == ^name)
      |> Repo.delete_all()

      Flux.Audit.record(scope, "workspace.env_var_delete",
        resource_type: "workspace_env_var",
        resource_id: name
      )

      :ok
    end
  end

  @doc "The decrypted map for runs (worker-safe: takes a workspace id)."
  def resolve(workspace_id) do
    EnvVar
    |> where([v], v.workspace_id == ^workspace_id)
    |> Repo.all(skip_workspace_guard: true)
    |> Map.new(fn var -> {var.name, decrypt_value(workspace_id, var) || ""} end)
  end

  defp decrypt_value(workspace_id, var) do
    case Crypto.decrypt(workspace_id, var.encrypted_value) do
      {:ok, value} -> value
      _undecryptable -> nil
    end
  end
end
