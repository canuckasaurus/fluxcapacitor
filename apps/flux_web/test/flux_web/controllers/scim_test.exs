defmodule FluxWeb.ScimTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "SCIM WS"})
    scope = Accounts.scope_for(account)
    {:ok, raw} = Accounts.enable_scim(scope)

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{raw}"),
      scope: scope,
      workspace: workspace,
      owner: account
    }
  end

  test "requests without a valid token are refused" do
    conn = build_conn() |> get(~p"/scim/v2/Users")
    assert json_response(conn, 401)["scimType"] == "invalidValue"

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer scim_wrong")
      |> get(~p"/scim/v2/Users")

    assert conn.status == 401
  end

  test "provision, list, filter, and show", %{conn: conn, owner: owner} do
    body =
      conn
      |> post(~p"/scim/v2/Users", %{"userName" => "Provisioned@example.com"})
      |> json_response(201)

    assert body["userName"] == "provisioned@example.com"
    assert body["active"] == true
    user_id = body["id"]

    # The account exists globally, confirmed, and is a normal member.
    account = Accounts.get_account_by_email("provisioned@example.com")
    assert account.id == user_id
    assert account.confirmed_at

    # Re-provisioning the same user is a 409 uniqueness error.
    assert conn
           |> post(~p"/scim/v2/Users", %{"userName" => "provisioned@example.com"})
           |> json_response(409)
           |> Map.fetch!("scimType") == "uniqueness"

    # List includes the owner and the new member.
    body = conn |> get(~p"/scim/v2/Users") |> json_response(200)
    assert body["totalResults"] == 2
    names = Enum.map(body["Resources"], & &1["userName"])
    assert owner.email in names
    assert "provisioned@example.com" in names

    # userName filter narrows to one.
    body =
      conn
      |> get(~p"/scim/v2/Users?#{[filter: ~s(userName eq "provisioned@example.com")]}")
      |> json_response(200)

    assert body["totalResults"] == 1

    assert conn |> get(~p"/scim/v2/Users/#{user_id}") |> json_response(200)
    assert conn |> get(~p"/scim/v2/Users/#{Ecto.UUID.generate()}") |> json_response(404)
  end

  test "deactivate via PATCH, reactivate, and DELETE", %{conn: conn, workspace: workspace} do
    user_id =
      conn
      |> post(~p"/scim/v2/Users", %{"userName" => "cycle@example.com"})
      |> json_response(201)
      |> Map.fetch!("id")

    # PATCH active=false removes the membership, keeps the account.
    body =
      conn
      |> patch(~p"/scim/v2/Users/#{user_id}", %{
        "Operations" => [%{"op" => "Replace", "value" => %{"active" => false}}]
      })
      |> json_response(200)

    assert body["active"] == false
    assert Accounts.scim_find_member(workspace.id, user_id) == nil
    assert Accounts.get_account_by_email("cycle@example.com")

    # PATCH active=true reprovisions from the surviving account.
    body =
      conn
      |> patch(~p"/scim/v2/Users/#{user_id}", %{
        "Operations" => [%{"op" => "Replace", "path" => "active", "value" => true}]
      })
      |> json_response(200)

    assert body["active"] == true
    assert Accounts.scim_find_member(workspace.id, user_id)

    # DELETE removes the membership outright.
    assert conn |> delete(~p"/scim/v2/Users/#{user_id}") |> response(204)
    assert Accounts.scim_find_member(workspace.id, user_id) == nil
  end

  test "the owner cannot be deprovisioned over SCIM", %{conn: conn, owner: owner} do
    assert conn
           |> delete(~p"/scim/v2/Users/#{owner.id}")
           |> json_response(403)
           |> Map.fetch!("scimType") == "mutability"

    assert conn
           |> patch(~p"/scim/v2/Users/#{owner.id}", %{
             "Operations" => [%{"op" => "replace", "value" => %{"active" => false}}]
           })
           |> json_response(403)
  end

  test "disabling SCIM revokes the token; rotation replaces it", %{conn: conn, scope: scope} do
    {:ok, rotated} = Accounts.enable_scim(scope)

    # The old token (in conn) no longer authenticates.
    assert conn |> get(~p"/scim/v2/Users") |> json_response(401)

    fresh = build_conn() |> put_req_header("authorization", "Bearer #{rotated}")
    assert fresh |> get(~p"/scim/v2/Users") |> json_response(200)

    :ok = Accounts.disable_scim(scope)
    assert fresh |> get(~p"/scim/v2/Users") |> json_response(401)
  end
end
