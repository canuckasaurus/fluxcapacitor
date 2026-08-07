defmodule Flux.MCP do
  @moduledoc """
  Model Context Protocol servers as workspace tool sources: point a
  workspace at a server URL and its tools join the picker alongside
  toolsets and plugin tools. Auth headers are encrypted per workspace;
  the tool list is cached at registration and refreshable.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Crypto
  alias Flux.MCP.Client
  alias Flux.RBAC
  alias Flux.Repo

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "mcp_servers" do
      belongs_to :workspace, Flux.Accounts.Workspace

      field :name, :string
      field :url, :string
      field :encrypted_headers, :string, redact: true
      field :tools, {:array, :map}, default: []

      timestamps(type: :utc_datetime)
    end

    def changeset(server, attrs) do
      server
      |> cast(attrs, [:name, :url])
      |> validate_required([:name, :url])
      |> validate_length(:name, min: 1, max: 120)
      |> validate_format(:url, ~r{^https?://}, message: "must be an http(s) URL")
      |> unique_constraint([:workspace_id, :name])
    end
  end

  def list_servers(%Scope{} = scope) do
    Server |> Repo.scoped(scope) |> order_by([s], asc: s.name) |> Repo.all()
  end

  def get_server(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(Server, id: ^id), scope)) || {:error, :not_found}
  end

  @doc """
  Registers a server after a live handshake — the tools it advertises
  are cached on the row. `attrs`: name, url, optional `"headers"` map
  (e.g. an Authorization header), stored encrypted.
  """
  def create_server(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :mcp_manage),
         headers = normalize_headers(attrs["headers"]),
         {:ok, tools} <- Client.list_tools(attrs["url"] || "", headers) do
      workspace_id = Scope.workspace_id(scope)

      changeset =
        %Server{workspace_id: workspace_id, tools: sanitize_tools(tools)}
        |> Server.changeset(attrs)
        |> put_encrypted_headers(workspace_id, headers)

      with {:ok, server} <- Repo.insert(changeset) do
        Flux.Audit.record(scope, "mcp_server.create", resource: server)
        {:ok, server}
      end
    end
  end

  @doc "Re-runs tools/list and refreshes the cached tool list."
  def refresh_server(%Scope{} = scope, id) do
    with :ok <- RBAC.authorize(scope, :mcp_manage),
         %Server{} = server <- get_server(scope, id),
         {:ok, tools} <- Client.list_tools(server.url, server_headers(server)) do
      server |> Ecto.Changeset.change(tools: sanitize_tools(tools)) |> Repo.update()
    end
  end

  def delete_server(%Scope{} = scope, id) do
    with :ok <- RBAC.authorize(scope, :mcp_manage),
         %Server{} = server <- get_server(scope, id),
         {:ok, deleted} <- Repo.delete(server) do
      Flux.Audit.record(scope, "mcp_server.delete", resource: server)
      {:ok, deleted}
    end
  end

  @doc "Calls a tool on a workspace's registered server (engine path)."
  def invoke_for_workspace(workspace_id, server_id, tool_name, args) when is_map(args) do
    server =
      Server
      |> where([s], s.id == ^server_id and s.workspace_id == ^workspace_id)
      |> Repo.one(skip_workspace_guard: true)

    case server do
      nil ->
        {:error, :not_found}

      %Server{} = server ->
        with {:ok, result} <-
               Client.call_tool(server.url, server_headers(server), tool_name, args) do
          {:ok, Map.put(result, :status, 200)}
        end
    end
  end

  defp server_headers(%Server{encrypted_headers: nil}), do: %{}

  defp server_headers(%Server{} = server) do
    case Crypto.decrypt(server.workspace_id, server.encrypted_headers) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{} = headers} -> headers
          _invalid -> %{}
        end

      _error ->
        %{}
    end
  end

  defp put_encrypted_headers(changeset, _workspace_id, headers) when headers == %{},
    do: changeset

  defp put_encrypted_headers(changeset, workspace_id, headers) do
    {:ok, ciphertext} = Crypto.encrypt(workspace_id, Jason.encode!(headers))
    Ecto.Changeset.put_change(changeset, :encrypted_headers, ciphertext)
  end

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.reject(fn {key, value} -> key == "" or value in [nil, ""] end)
    |> Map.new(fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp normalize_headers(_absent), do: %{}

  # Only what the picker and the model need — no unbounded payloads.
  defp sanitize_tools(tools) do
    for %{"name" => name} = tool <- tools do
      %{
        "name" => name,
        "description" => String.slice(to_string(tool["description"] || ""), 0, 500),
        "input_schema" => tool["inputSchema"] || %{}
      }
    end
  end
end
