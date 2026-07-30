defmodule Flux.ToolsTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Tools
  alias Flux.Tools.OpenAPI

  @petstore_json """
  {
    "openapi": "3.0.0",
    "info": {"title": "Petstore", "description": "Pets API"},
    "servers": [{"url": "https://petstore.example.com/v2"}],
    "components": {
      "schemas": {
        "NewPet": {
          "type": "object",
          "required": ["name"],
          "properties": {
            "name": {"type": "string", "description": "Pet name"},
            "tag": {"type": "string"}
          }
        }
      }
    },
    "paths": {
      "/pets": {
        "get": {
          "operationId": "listPets",
          "summary": "List all pets",
          "parameters": [
            {"name": "limit", "in": "query", "schema": {"type": "integer"}},
            {"name": "X-Trace", "in": "header", "schema": {"type": "string"}}
          ]
        },
        "post": {
          "operationId": "createPet",
          "requestBody": {
            "content": {
              "application/json": {"schema": {"$ref": "#/components/schemas/NewPet"}}
            }
          }
        }
      },
      "/pets/{petId}": {
        "get": {
          "summary": "Get one pet",
          "parameters": [
            {"name": "petId", "in": "path", "required": true, "schema": {"type": "string"}}
          ]
        }
      }
    }
  }
  """

  setup do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Tools WS"})
    scope = Accounts.scope_for(account)
    %{scope: scope}
  end

  describe "OpenAPI.parse/1" do
    test "parses operations, params, and body properties from JSON" do
      assert {:ok, parsed} = OpenAPI.parse(@petstore_json)
      assert parsed.title == "Petstore"
      assert parsed.base_url == "https://petstore.example.com/v2"

      ids = Enum.map(parsed.operations, & &1["operation_id"])
      assert "listPets" in ids
      assert "createPet" in ids
      # Missing operationId falls back to method + path slug.
      assert "get_pets_petId" in ids

      list_pets = Enum.find(parsed.operations, &(&1["operation_id"] == "listPets"))
      assert %{"name" => "limit", "in" => "query", "type" => "integer"} = hd(list_pets["params"])

      create_pet = Enum.find(parsed.operations, &(&1["operation_id"] == "createPet"))

      body_names =
        for %{"in" => "body"} = p <- create_pet["params"], do: {p["name"], p["required"]}

      assert {"name", true} in body_names
      assert {"tag", false} in body_names
    end

    test "parses YAML and Swagger 2 host/basePath" do
      yaml = """
      swagger: "2.0"
      info:
        title: Legacy
      host: legacy.example.com
      basePath: /api
      schemes: [https]
      paths:
        /things:
          get:
            operationId: listThings
      """

      assert {:ok, parsed} = OpenAPI.parse(yaml)
      assert parsed.base_url == "https://legacy.example.com/api"
      assert [%{"operation_id" => "listThings"}] = parsed.operations
    end

    test "rejects specs without paths or version" do
      assert {:error, message} = OpenAPI.parse(~s({"openapi": "3.0.0", "paths": {}}))
      assert message =~ "no paths"

      assert {:error, message} = OpenAPI.parse(~s({"paths": {"/x": {}}}))
      assert message =~ "version"

      assert {:error, _message} = OpenAPI.parse(": not: valid: [json")
    end
  end

  describe "toolsets" do
    test "create parses and stores operations; auth and variables round-trip encrypted", %{
      scope: scope
    } do
      {:ok, toolset} = Tools.create_toolset(scope, "Petstore", @petstore_json)
      assert length(toolset.operations) == 3
      assert toolset.base_url == "https://petstore.example.com/v2"

      {:ok, toolset} =
        Tools.put_auth(scope, toolset, %{
          "type" => "api_key",
          "in" => "header",
          "name" => "X-API-Key",
          "value" => "super-secret"
        })

      {:ok, toolset} = Tools.put_variables(scope, toolset, %{"tenant" => "acme-corp"})

      # Raw columns never contain the plaintext.
      refute toolset.encrypted_auth =~ "super-secret"
      refute toolset.encrypted_variables =~ "acme-corp"

      summary = Tools.security_summary(toolset)
      assert summary.auth_type == "api_key"
      assert summary.variable_names == ["tenant"]
    end

    test "toolsets are workspace-scoped and RBAC-gated", %{scope: scope} do
      {:ok, toolset} = Tools.create_toolset(scope, "Mine", @petstore_json)

      other = account_fixture()
      {:ok, _} = Accounts.create_workspace(other, %{name: "Other"})
      other_scope = Accounts.scope_for(other)

      assert Tools.list_toolsets(other_scope) == []
      assert {:error, :not_found} = Tools.get_toolset(other_scope, toolset.id)

      member = account_fixture()

      {:ok, _} =
        %Flux.Accounts.Membership{}
        |> Flux.Accounts.Membership.changeset(%{
          workspace_id: toolset.workspace_id,
          account_id: member.id,
          role: :editor
        })
        |> Repo.insert()

      {:ok, _} = Accounts.switch_workspace(member, toolset.workspace_id)
      member_scope = Accounts.scope_for(member)

      # Editors lack :tool_manage — only owner/admin manage toolsets.
      assert {:error, :unauthorized} = Tools.create_toolset(member_scope, "No", @petstore_json)
      assert {:error, :unauthorized} = Tools.put_variables(member_scope, toolset, %{})
    end
  end

  describe "invoke_for_workspace/4" do
    setup %{scope: scope} do
      {:ok, toolset} = Tools.create_toolset(scope, "Petstore", @petstore_json)

      {:ok, toolset} =
        Tools.put_auth(scope, toolset, %{
          "type" => "api_key",
          "in" => "header",
          "name" => "X-API-Key",
          "value" => "super-secret"
        })

      {:ok, toolset} = Tools.put_variables(scope, toolset, %{"tenant" => "acme-corp"})

      Application.put_env(:flux, :tools_req_options, plug: {Req.Test, Flux.ToolsStub})
      on_exit(fn -> Application.delete_env(:flux, :tools_req_options) end)

      %{toolset: toolset}
    end

    test "builds the request with path/query/header/body args, auth, and vars", %{
      toolset: toolset
    } do
      parent = self()

      Req.Test.stub(Flux.ToolsStub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        send(
          parent,
          {:request, conn.method, conn.request_path, conn.query_params, conn.req_headers}
        )

        Req.Test.json(conn, %{"pets" => [%{"name" => "Rex"}]})
      end)

      assert {:ok, result} =
               Tools.invoke_for_workspace(toolset.workspace_id, toolset.id, "listPets", %{
                 "limit" => "5",
                 "X-Trace" => "{{vars.tenant}}"
               })

      assert result.status == 200
      assert result.body["pets"] == [%{"name" => "Rex"}]
      assert result.text =~ "Rex"

      assert_received {:request, "GET", "/v2/pets", query, headers}
      assert query["limit"] == "5"
      assert {"x-api-key", "super-secret"} in headers
      # {{vars.tenant}} was substituted server-side.
      assert {"x-trace", "acme-corp"} in headers
    end

    test "substitutes path params and posts JSON bodies", %{toolset: toolset} do
      parent = self()

      Req.Test.stub(Flux.ToolsStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request, conn.method, conn.request_path, body})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} =
               Tools.invoke_for_workspace(toolset.workspace_id, toolset.id, "get_pets_petId", %{
                 "petId" => "42"
               })

      assert_received {:request, "GET", "/v2/pets/42", _body}

      assert {:ok, _} =
               Tools.invoke_for_workspace(toolset.workspace_id, toolset.id, "createPet", %{
                 "name" => "Fido"
               })

      assert_received {:request, "POST", "/v2/pets", body}
      assert Jason.decode!(body) == %{"name" => "Fido"}
    end

    test "unknown toolset or operation errors cleanly", %{toolset: toolset} do
      assert {:error, :unknown_toolset} =
               Tools.invoke_for_workspace(toolset.workspace_id, "not-a-uuid", "listPets", %{})

      assert {:error, :unknown_operation} =
               Tools.invoke_for_workspace(toolset.workspace_id, toolset.id, "nope", %{})
    end
  end
end
