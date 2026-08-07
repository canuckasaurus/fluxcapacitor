defmodule Flux.Tools do
  @moduledoc """
  Custom API toolsets: import an OpenAPI spec, every operation becomes a
  callable tool.

  Auth and private variables are encrypted per workspace via `Flux.Crypto`
  and only decrypted inside `invoke_for_workspace/4` at call time — they
  never travel to the UI or into run traces.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Crypto
  alias Flux.RBAC
  alias Flux.Repo
  alias Flux.Tools.{ApiToolset, OpenAPI}

  @receive_timeout :timer.seconds(60)

  ## Toolsets

  def list_toolsets(%Scope{} = scope) do
    ApiToolset |> Repo.scoped(scope) |> order_by([t], asc: t.name) |> Repo.all()
  end

  def get_toolset(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(ApiToolset, id: ^id), scope)) || {:error, :not_found}
  end

  @doc "Parses the spec text and creates the toolset with its operations."
  def create_toolset(%Scope{} = scope, name, spec_text) do
    with :ok <- RBAC.authorize(scope, :tool_manage),
         {:ok, parsed} <- OpenAPI.parse(spec_text) do
      %ApiToolset{
        workspace_id: Scope.workspace_id(scope),
        created_by_id: Scope.account_id(scope),
        spec: %{},
        operations: parsed.operations
      }
      |> ApiToolset.changeset(%{
        "name" => presence(name) || parsed.title,
        "description" => parsed.description,
        "base_url" => parsed.base_url
      })
      |> Repo.insert()
    end
  end

  def update_toolset(%Scope{} = scope, %ApiToolset{} = toolset, attrs) do
    with :ok <- RBAC.authorize(scope, :tool_manage),
         :ok <- owned(scope, toolset) do
      toolset |> ApiToolset.changeset(attrs) |> Repo.update()
    end
  end

  def delete_toolset(%Scope{} = scope, %ApiToolset{} = toolset) do
    with :ok <- RBAC.authorize(scope, :tool_manage),
         :ok <- owned(scope, toolset) do
      Repo.delete(toolset)
    end
  end

  ## Encrypted auth & private variables

  @auth_types ~w(none api_key bearer)

  def auth_types, do: @auth_types

  @doc """
  Stores the auth config encrypted. Shape:
  `%{"type" => "none" | "api_key" | "bearer", "in" => "header" | "query",
  "name" => header/param name, "value" => secret}`.
  """
  def put_auth(%Scope{} = scope, %ApiToolset{} = toolset, %{"type" => type} = auth)
      when type in @auth_types do
    with :ok <- RBAC.authorize(scope, :tool_manage),
         :ok <- owned(scope, toolset),
         {:ok, encrypted} <- Crypto.encrypt(toolset.workspace_id, Jason.encode!(auth)) do
      toolset |> Ecto.Changeset.change(encrypted_auth: encrypted) |> Repo.update()
    end
  end

  @doc "Stores the private variables map (`%{name => secret}`) encrypted."
  def put_variables(%Scope{} = scope, %ApiToolset{} = toolset, variables)
      when is_map(variables) do
    with :ok <- RBAC.authorize(scope, :tool_manage),
         :ok <- owned(scope, toolset),
         {:ok, encrypted} <- Crypto.encrypt(toolset.workspace_id, Jason.encode!(variables)) do
      toolset |> Ecto.Changeset.change(encrypted_variables: encrypted) |> Repo.update()
    end
  end

  @doc "Adds/overwrites one private variable in the encrypted map."
  def merge_variable(%Scope{} = scope, %ApiToolset{} = toolset, name, value) do
    current = decrypt_map(toolset, :encrypted_variables) || %{}
    put_variables(scope, toolset, Map.put(current, name, value))
  end

  @doc "Removes one private variable from the encrypted map."
  def delete_variable(%Scope{} = scope, %ApiToolset{} = toolset, name) do
    current = decrypt_map(toolset, :encrypted_variables) || %{}
    put_variables(scope, toolset, Map.delete(current, name))
  end

  @doc "Auth type plus variable names for display — never the secrets."
  def security_summary(%ApiToolset{} = toolset) do
    %{
      auth_type: (decrypt_map(toolset, :encrypted_auth) || %{})["type"] || "none",
      variable_names: toolset |> decrypt_map(:encrypted_variables) |> Kernel.||(%{}) |> Map.keys()
    }
  end

  ## Invocation

  @doc "Finds the operation on a toolset."
  def find_operation(%ApiToolset{operations: operations}, operation_id) do
    Enum.find(operations, &(&1["operation_id"] == operation_id)) ||
      {:error, :unknown_operation}
  end

  @doc """
  Executes an operation with `args` (`%{param_name => value}`). Secrets are
  decrypted here, injected into the request, and `{{vars.name}}` references
  in argument values are substituted server-side.
  """
  # `plugin:<id>` toolset ids route to installed tool plugins.
  def invoke_for_workspace(workspace_id, "mcp:" <> server_id, operation_id, args)
      when is_map(args) do
    Flux.MCP.invoke_for_workspace(workspace_id, server_id, operation_id, args)
  end

  def invoke_for_workspace(workspace_id, "plugin:" <> plugin_id, operation_id, args)
      when is_map(args) do
    if plugin_installed?(workspace_id, plugin_id) do
      case plugin_runtime().invoke_tool_plugin(plugin_id, %{}, operation_id, args) do
        {:ok, %{text: _text} = result} -> {:ok, Map.put_new(result, :status, 200)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :plugin_not_installed}
    end
  end

  def invoke_for_workspace(workspace_id, toolset_id, operation_id, args)
      when is_map(args) do
    with {:ok, uuid} <- cast_uuid(toolset_id),
         %ApiToolset{} = toolset <- fetch_workspace_toolset(workspace_id, uuid),
         %{} = operation <- find_operation(toolset, operation_id) do
      request(toolset, operation, args)
    end
  end

  ## Tool-plugin installations

  defp plugin_runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

  def list_installed_plugin_ids(%Scope{} = scope) do
    workspace_id = Scope.workspace_id(scope)

    from(i in "plugin_installations",
      where: i.workspace_id == type(^workspace_id, :binary_id),
      select: i.plugin_id
    )
    |> Repo.all()
  end

  def plugin_installed?(workspace_id, plugin_id) do
    from(i in "plugin_installations",
      where: i.workspace_id == type(^workspace_id, :binary_id) and i.plugin_id == ^plugin_id,
      select: i.plugin_id
    )
    |> Repo.exists?()
  end

  def install_plugin(%Scope{} = scope, plugin_id) do
    with :ok <- RBAC.authorize(scope, :plugin_install) do
      Repo.insert_all(
        "plugin_installations",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            workspace_id: Ecto.UUID.dump!(Scope.workspace_id(scope)),
            plugin_id: plugin_id,
            endpoint_token:
              "ep_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
            inserted_at: DateTime.utc_now(:second)
          }
        ],
        on_conflict: :nothing
      )

      Flux.Audit.record(scope, "plugin.install",
        resource_type: "plugin",
        resource_id: plugin_id
      )

      :ok
    end
  end

  @doc "The installation's endpoint token for display, or nil when not installed."
  def endpoint_token(%Scope{} = scope, plugin_id) do
    workspace_id = Scope.workspace_id(scope)

    from(i in "plugin_installations",
      where: i.workspace_id == type(^workspace_id, :binary_id) and i.plugin_id == ^plugin_id,
      select: i.endpoint_token
    )
    |> Repo.one()
  end

  @doc "Resolves an endpoint token to `%{workspace_id, plugin_id}` for routing."
  def installation_by_endpoint_token("ep_" <> _rest = token) do
    from(i in "plugin_installations",
      where: i.endpoint_token == ^token,
      select: %{workspace_id: type(i.workspace_id, :binary_id), plugin_id: i.plugin_id}
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      installation -> {:ok, installation}
    end
  end

  def installation_by_endpoint_token(_token), do: {:error, :not_found}

  def uninstall_plugin(%Scope{} = scope, plugin_id) do
    with :ok <- RBAC.authorize(scope, :plugin_install) do
      from(i in "plugin_installations",
        where:
          i.workspace_id == type(^Scope.workspace_id(scope), :binary_id) and
            i.plugin_id == ^plugin_id
      )
      |> Repo.delete_all()

      Flux.Audit.record(scope, "plugin.uninstall",
        resource_type: "plugin",
        resource_id: plugin_id
      )

      :ok
    end
  end

  @doc """
  Installed tool plugins presented as pseudo-toolsets (`plugin:<id>`),
  merged with API toolsets in the editor's toolset pickers.
  """
  def installed_plugin_toolsets(%Scope{} = scope) do
    installed = MapSet.new(list_installed_plugin_ids(scope))

    for manifest <- plugin_runtime().list_tool_plugins(),
        MapSet.member?(installed, manifest.id),
        {:ok, operations} = plugin_runtime().tool_operations(manifest.id, %{}) do
      %{
        id: "plugin:" <> manifest.id,
        name: manifest.name <> " (plugin)",
        operations:
          for operation <- operations do
            %{
              "operation_id" => operation.id,
              "name" => operation.name,
              "description" => operation.description,
              "parameters" => operation.parameters
            }
          end
      }
    end
  end

  @doc """
  Registered MCP servers shaped like toolsets for the picker: id
  `"mcp:<server_id>"`, one operation per advertised tool.
  """
  def mcp_toolsets(%Scope{} = scope) do
    for server <- Flux.MCP.list_servers(scope) do
      %{
        id: "mcp:" <> server.id,
        name: server.name <> " (MCP)",
        operations:
          for tool <- server.tools do
            %{
              "operation_id" => tool["name"],
              "name" => tool["name"],
              "description" => tool["description"],
              "parameters" => tool["input_schema"]
            }
          end
      }
    end
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :unknown_toolset}
    end
  end

  defp fetch_workspace_toolset(workspace_id, id) do
    Repo.one(from(t in ApiToolset, where: t.id == ^id and t.workspace_id == ^workspace_id)) ||
      {:error, :unknown_toolset}
  end

  defp request(toolset, operation, args) do
    variables = decrypt_map(toolset, :encrypted_variables) || %{}
    auth = decrypt_map(toolset, :encrypted_auth) || %{"type" => "none"}

    args =
      Map.new(args, fn {key, value} -> {key, substitute_vars(value, variables)} end)

    {url, query, headers, body} = build_request(toolset, operation, args)
    {query, headers} = apply_auth(auth, query, headers)

    with :ok <- Flux.SSRF.verify_url(url) do
      dispatch(operation, url, query, headers, body)
    end
  end

  defp dispatch(operation, url, query, headers, body) do
    options =
      [
        method: String.to_existing_atom(operation["method"]),
        url: url,
        params: query,
        headers: headers,
        receive_timeout: @receive_timeout,
        retry: false
      ]
      |> then(fn options -> if body == %{}, do: options, else: options ++ [json: body] end)
      |> Keyword.merge(Application.get_env(:flux, :tools_req_options, []))

    case Req.request(options) do
      {:ok, %{status: status, body: response}} ->
        {:ok, %{status: status, body: response, text: as_text(response)}}

      {:error, reason} ->
        {:error, "API call failed: #{inspect(reason)}"}
    end
  end

  defp build_request(toolset, operation, args) do
    path =
      Enum.reduce(operation["params"], operation["path"], fn
        %{"in" => "path", "name" => name}, path ->
          String.replace(path, "{#{name}}", to_string(args[name] || ""))

        _other, path ->
          path
      end)

    grouped = Enum.group_by(operation["params"], & &1["in"])

    query =
      for %{"name" => name} <- grouped["query"] || [], args[name] not in [nil, ""] do
        {name, args[name]}
      end

    headers =
      for %{"name" => name} <- grouped["header"] || [], args[name] not in [nil, ""] do
        {name, to_string(args[name])}
      end

    body =
      for %{"name" => name} = param <- grouped["body"] || [],
          args[name] not in [nil, ""],
          into: %{} do
        {name, coerce_arg(param["type"], args[name])}
      end

    {String.trim_trailing(toolset.base_url, "/") <> path, query, headers, body}
  end

  # JSON body values follow the spec's declared type; strings that don't
  # parse are passed through as-is (let the API report the type error).
  defp coerce_arg("integer", value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _not_integer -> value
    end
  end

  defp coerce_arg("number", value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _not_number -> value
    end
  end

  defp coerce_arg("boolean", value) when is_binary(value),
    do: String.downcase(value) in ["true", "1", "yes"]

  defp coerce_arg(_type, value), do: value

  defp apply_auth(%{"type" => "api_key"} = auth, query, headers) do
    name = presence(auth["name"]) || "X-API-Key"
    value = auth["value"] || ""

    case auth["in"] do
      "query" -> {query ++ [{name, value}], headers}
      _header -> {query, headers ++ [{name, value}]}
    end
  end

  defp apply_auth(%{"type" => "bearer"} = auth, query, headers) do
    {query, headers ++ [{"authorization", "Bearer " <> (auth["value"] || "")}]}
  end

  defp apply_auth(_none, query, headers), do: {query, headers}

  defp substitute_vars(value, variables) when is_binary(value) do
    Regex.replace(~r/\{\{\s*vars\.([\w-]+)\s*\}\}/, value, fn _whole, name ->
      to_string(Map.get(variables, name, ""))
    end)
  end

  defp substitute_vars(value, _variables), do: value

  defp decrypt_map(toolset, field) do
    with ciphertext when is_binary(ciphertext) <- Map.get(toolset, field),
         {:ok, json} <- Crypto.decrypt(toolset.workspace_id, ciphertext),
         {:ok, decoded} <- Jason.decode(json) do
      decoded
    else
      _absent_or_invalid -> nil
    end
  end

  defp as_text(body) when is_binary(body), do: body
  defp as_text(body), do: Jason.encode!(body)

  defp presence(nil), do: nil
  defp presence(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  defp owned(scope, %{workspace_id: workspace_id}) do
    if workspace_id == Scope.workspace_id(scope), do: :ok, else: {:error, :not_found}
  end
end
