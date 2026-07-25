defmodule FluxWeb.ConsoleLive.Members do
  @moduledoc false
  use FluxWeb, :live_view

  alias Flux.Accounts
  alias Flux.Accounts.Invitation
  alias Flux.RBAC

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Members")
     |> assign(invite_form: to_form(%{"emails" => "", "role" => "editor"}, as: :invite))
     |> refresh()}
  end

  defp refresh(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      members: Accounts.list_members(scope),
      pending: Accounts.list_pending_invitations(scope),
      can_manage: RBAC.can?(scope, :workspace_member_manage)
    )
  end

  @impl true
  def handle_event("invite", %{"invite" => %{"emails" => emails, "role" => role}}, socket) do
    if socket.assigns.can_manage do
      role = String.to_existing_atom(role)

      emails =
        emails
        |> String.split([",", ";", "\n", " "], trim: true)
        |> Enum.uniq()

      case emails do
        [] ->
          {:noreply, put_flash(socket, :error, "Enter at least one email address.")}

        emails ->
          {oks, errors} = Accounts.create_invitations(socket.assigns.current_scope, emails, role)

          deliver_invites(socket, oks)

          socket =
            socket
            |> maybe_flash_ok(oks)
            |> maybe_flash_errors(errors)
            |> assign(invite_form: to_form(%{"emails" => "", "role" => role}, as: :invite))
            |> refresh()

          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to invite members.")}
    end
  end

  def handle_event("change-role", %{"membership-id" => id, "role" => role}, socket) do
    with true <- socket.assigns.can_manage,
         {_account, membership} <-
           Enum.find(socket.assigns.members, fn {_a, m} -> m.id == id end),
         {:ok, _} <-
           Accounts.update_member_role(
             socket.assigns.current_scope,
             membership,
             String.to_existing_atom(role)
           ) do
      {:noreply, socket |> put_flash(:info, "Role updated.") |> refresh()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update that member's role.")}
    end
  end

  def handle_event("remove-member", %{"membership-id" => id}, socket) do
    with true <- socket.assigns.can_manage,
         {_account, membership} <-
           Enum.find(socket.assigns.members, fn {_a, m} -> m.id == id end),
         {:ok, _} <- Accounts.remove_member(socket.assigns.current_scope, membership) do
      {:noreply, socket |> put_flash(:info, "Member removed.") |> refresh()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not remove that member.")}
    end
  end

  def handle_event("revoke-invitation", %{"invitation-id" => id}, socket) do
    with true <- socket.assigns.can_manage,
         {:ok, _} <- Accounts.revoke_invitation(socket.assigns.current_scope, id) do
      {:noreply, socket |> put_flash(:info, "Invitation revoked.") |> refresh()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not revoke that invitation.")}
    end
  end

  defp deliver_invites(socket, oks) do
    workspace = socket.assigns.current_scope.workspace
    inviter = socket.assigns.current_scope.account

    for {_email, {:ok, {invitation, raw_token}}} <- oks do
      Accounts.deliver_invitation(
        invitation,
        workspace,
        inviter,
        url(~p"/invitations/accept/#{raw_token}")
      )
    end
  end

  defp maybe_flash_ok(socket, []), do: socket

  defp maybe_flash_ok(socket, oks),
    do: put_flash(socket, :info, "#{length(oks)} invitation(s) sent.")

  defp maybe_flash_errors(socket, []), do: socket

  defp maybe_flash_errors(socket, errors) do
    failed = Enum.map_join(errors, ", ", fn {email, _} -> email end)
    put_flash(socket, :error, "Could not invite: #{failed}")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console flash={@flash} current_scope={@current_scope} active={:members}>
      <div>
        <h1 class="text-2xl font-bold">Members</h1>
        <p class="opacity-70 mt-1">
          People with access to {@current_scope.workspace.name}.
        </p>
      </div>

      <div :if={@can_manage} class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Invite people</h2>
        <.form
          for={@invite_form}
          id="invite-form"
          phx-submit="invite"
          class="flex flex-wrap gap-3 items-end"
        >
          <div class="flex-1 min-w-64">
            <.input
              field={@invite_form[:emails]}
              type="text"
              label="Email addresses"
              placeholder="alice@company.com, bob@company.com"
            />
          </div>
          <div class="w-44">
            <.input
              field={@invite_form[:role]}
              type="select"
              label="Role"
              options={[
                {"Admin", "admin"},
                {"Editor", "editor"},
                {"Member", "normal"},
                {"Knowledge operator", "dataset_operator"}
              ]}
            />
          </div>
          <button class="btn btn-primary">Send invites</button>
        </.form>
      </div>

      <div class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Current members ({length(@members)})</h2>
        <table class="table">
          <thead>
            <tr>
              <th>Email</th>
              <th>Role</th>
              <th>Joined</th>
              <th :if={@can_manage}></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{account, membership} <- @members} id={"member-#{membership.id}"}>
              <td>{account.email}</td>
              <td>
                <span :if={membership.role == :owner} class="badge badge-primary">owner</span>
                <form
                  :if={membership.role != :owner and @can_manage}
                  phx-change="change-role"
                >
                  <input type="hidden" name="membership-id" value={membership.id} />
                  <select name="role" class="select select-sm select-bordered">
                    <option
                      :for={
                        {label, value} <- [
                          {"admin", "admin"},
                          {"editor", "editor"},
                          {"member", "normal"},
                          {"knowledge operator", "dataset_operator"}
                        ]
                      }
                      value={value}
                      selected={to_string(membership.role) == value}
                    >
                      {label}
                    </option>
                  </select>
                </form>
                <span :if={membership.role != :owner and not @can_manage} class="badge">
                  {membership.role}
                </span>
              </td>
              <td class="text-sm opacity-70">
                {Calendar.strftime(membership.inserted_at, "%b %d, %Y")}
              </td>
              <td :if={@can_manage} class="text-right">
                <button
                  :if={
                    membership.role != :owner and
                      membership.account_id != @current_scope.account.id
                  }
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="remove-member"
                  phx-value-membership-id={membership.id}
                  data-confirm={"Remove #{account.email} from this workspace?"}
                >
                  Remove
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@can_manage and @pending != []} class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Pending invitations ({length(@pending)})</h2>
        <table class="table">
          <thead>
            <tr>
              <th>Email</th>
              <th>Role</th>
              <th>Expires</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={%Invitation{} = invitation <- @pending} id={"invitation-#{invitation.id}"}>
              <td>{invitation.email}</td>
              <td><span class="badge">{invitation.role}</span></td>
              <td class="text-sm opacity-70">
                {Calendar.strftime(invitation.expires_at, "%b %d, %Y")}
              </td>
              <td class="text-right">
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="revoke-invitation"
                  phx-value-invitation-id={invitation.id}
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end
end
