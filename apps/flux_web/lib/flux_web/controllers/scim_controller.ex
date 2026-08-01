defmodule FluxWeb.ScimController do
  @moduledoc """
  SCIM 2.0 Users subset for IdP-driven provisioning (Okta, Entra,
  Keycloak, …). The workspace-bound bearer token (minted in workspace
  settings) is the authorization; provisioned accounts arrive confirmed
  as `:normal` members, and deprovisioning removes the membership —
  never the global account. Owners cannot be deprovisioned over SCIM.
  """
  use FluxWeb, :controller

  alias Flux.Accounts

  plug :authenticate

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"
  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  def index(conn, params) do
    members = Accounts.scim_list_members(conn.assigns.scim_workspace.id)

    members =
      case parse_filter(params["filter"]) do
        {:user_name, email} ->
          Enum.filter(members, &(String.downcase(&1.account.email) == String.downcase(email)))

        nil ->
          members
      end

    scim_json(conn, 200, %{
      "schemas" => [@list_schema],
      "totalResults" => length(members),
      "startIndex" => 1,
      "itemsPerPage" => length(members),
      "Resources" => Enum.map(members, &user_resource/1)
    })
  end

  def create(conn, params) do
    email = params["userName"] || get_in(params, ["emails", Access.at(0), "value"])

    if is_binary(email) and email =~ "@" do
      case Accounts.scim_provision(conn.assigns.scim_workspace, email) do
        {:ok, membership} ->
          scim_json(conn, 201, user_resource(membership))

        {:error, :conflict} ->
          scim_error(conn, 409, "uniqueness", "user already provisioned")

        {:error, _changeset} ->
          scim_error(conn, 400, "invalidValue", "could not provision user")
      end
    else
      scim_error(conn, 400, "invalidValue", "userName must be an email address")
    end
  end

  def show(conn, %{"id" => id}) do
    case Accounts.scim_find_member(conn.assigns.scim_workspace.id, id) do
      nil -> scim_error(conn, 404, "invalidValue", "user not found")
      membership -> scim_json(conn, 200, user_resource(membership))
    end
  end

  # Only the `active` attribute is writable: false deprovisions, true
  # (re-)provisions. Everything else in the payload is ignored.
  def patch(conn, %{"id" => id} = params) do
    apply_active(conn, id, active_from_operations(params["Operations"]))
  end

  def put(conn, %{"id" => id} = params) do
    apply_active(conn, id, params["active"])
  end

  def delete(conn, %{"id" => id}) do
    case Accounts.scim_deprovision(conn.assigns.scim_workspace, id) do
      :ok -> send_resp(conn, 204, "")
      {:error, :owner} -> scim_error(conn, 403, "mutability", "the owner cannot be deprovisioned")
      {:error, :not_found} -> scim_error(conn, 404, "invalidValue", "user not found")
    end
  end

  defp apply_active(conn, id, active) do
    workspace = conn.assigns.scim_workspace

    case {active, Accounts.scim_find_member(workspace.id, id)} do
      {false, %{} = membership} ->
        case Accounts.scim_deprovision(workspace, id) do
          :ok ->
            scim_json(conn, 200, membership |> user_resource() |> Map.put("active", false))

          {:error, :owner} ->
            scim_error(conn, 403, "mutability", "the owner cannot be deprovisioned")
        end

      {true, %{} = membership} ->
        scim_json(conn, 200, user_resource(membership))

      {true, nil} ->
        # Reactivation: the account may exist without a membership.
        case Flux.Repo.get(Flux.Accounts.Account, id) do
          nil ->
            scim_error(conn, 404, "invalidValue", "user not found")

          account ->
            case Accounts.scim_provision(workspace, account.email) do
              {:ok, membership} -> scim_json(conn, 200, user_resource(membership))
              {:error, _reason} -> scim_error(conn, 400, "invalidValue", "could not reactivate")
            end
        end

      {_no_active_change, %{} = membership} ->
        scim_json(conn, 200, user_resource(membership))

      {_any, nil} ->
        scim_error(conn, 404, "invalidValue", "user not found")
    end
  end

  defp active_from_operations(operations) when is_list(operations) do
    operations
    # Wrapped in a tuple: a bare `false` would read as "keep looking".
    |> Enum.find_value(fn operation ->
      value = operation["value"]

      cond do
        is_map(value) and is_boolean(value["active"]) ->
          {:ok, value["active"]}

        operation["path"] in ["active", "Active"] and is_boolean(value) ->
          {:ok, value}

        operation["path"] in ["active", "Active"] and value in ["true", "false"] ->
          {:ok, value == "true"}

        true ->
          nil
      end
    end)
    |> case do
      {:ok, active} -> active
      nil -> nil
    end
  end

  defp active_from_operations(_operations), do: nil

  defp user_resource(membership) do
    %{
      "schemas" => [@user_schema],
      "id" => membership.account_id,
      "userName" => membership.account.email,
      "active" => true,
      "emails" => [%{"value" => membership.account.email, "primary" => true}],
      "meta" => %{"resourceType" => "User"}
    }
  end

  # The only filter IdPs need for provisioning: userName eq "email".
  defp parse_filter(filter) when is_binary(filter) do
    case Regex.run(~r/^userName\s+eq\s+"([^"]+)"$/i, String.trim(filter)) do
      [_whole, email] -> {:user_name, email}
      nil -> nil
    end
  end

  defp parse_filter(_filter), do: nil

  defp scim_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/scim+json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp scim_error(conn, status, type, detail) do
    scim_json(conn, status, %{
      "schemas" => [@error_schema],
      "scimType" => type,
      "detail" => detail,
      "status" => to_string(status)
    })
  end

  defp authenticate(conn, _opts) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         {:ok, workspace} <- Accounts.workspace_by_scim_token(raw) do
      assign(conn, :scim_workspace, workspace)
    else
      _missing_or_invalid ->
        conn
        |> scim_error(401, "invalidValue", "a valid SCIM bearer token is required")
        |> halt()
    end
  end
end
