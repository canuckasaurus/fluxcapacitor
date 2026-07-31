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
      can_manage: RBAC.can?(scope, :workspace_member_manage),
      can_manage_roles: RBAC.can?(scope, :workspace_role_manage),
      roles: RBAC.list_roles(scope)
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

  def handle_event("create-role", params, socket) do
    permissions =
      params
      |> Map.get("permissions", %{})
      |> Enum.filter(fn {_permission, checked} -> checked == "true" end)
      |> Enum.map(fn {permission, _} -> permission end)

    case RBAC.create_role(socket.assigns.current_scope, %{
           "name" => params["name"],
           "permissions" => permissions
         }) do
      {:ok, role} ->
        {:noreply, socket |> put_flash(:info, "Role \"#{role.name}\" created.") |> refresh()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage roles.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, role_error(changeset))}
    end
  end

  def handle_event("delete-role", %{"role-id" => id}, socket) do
    case RBAC.delete_role(socket.assigns.current_scope, id) do
      {:ok, _role} -> {:noreply, socket |> put_flash(:info, "Role deleted.") |> refresh()}
      _error -> {:noreply, put_flash(socket, :error, "Could not delete that role.")}
    end
  end

  def handle_event(
        "assign-custom-role",
        %{"membership-id" => id, "custom-role" => role_id},
        socket
      ) do
    with {_account, membership} <-
           Enum.find(socket.assigns.members, fn {_a, m} -> m.id == id end),
         {:ok, _} <-
           RBAC.assign_custom_role(
             socket.assigns.current_scope,
             membership,
             (role_id == "" && nil) || role_id
           ) do
      {:noreply, socket |> put_flash(:info, "Custom role updated.") |> refresh()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update the custom role.")}
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

  defp role_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end

  defp permission_groups do
    [
      {"App", Flux.RBAC.Permission.app_scope()},
      {"Knowledge", Flux.RBAC.Permission.dataset_scope()},
      {"Workspace", Flux.RBAC.Permission.workspace_scope()}
    ]
  end

  defp maybe_flash_ok(socket, []), do: socket

  defp maybe_flash_ok(socket, oks),
    do: put_flash(socket, :info, "#{length(oks)} invitation(s) sent.")

  defp maybe_flash_errors(socket, []), do: socket

  defp maybe_flash_errors(socket, errors) do
    failed = Enum.map_join(errors, ", ", fn {email, _} -> email end)
    put_flash(socket, :error, "Could not invite: #{failed}")
  end

  # Owner and admins sit above the divider; everyone else below it.
  defp leaders(members) do
    members
    |> Enum.filter(fn {_account, membership} -> membership.role in [:owner, :admin] end)
    |> Enum.sort_by(fn {account, membership} -> {membership.role != :owner, account.email} end)
  end

  defp regulars(members) do
    members
    |> Enum.filter(fn {_account, membership} -> membership.role not in [:owner, :admin] end)
    |> Enum.sort_by(fn {account, _membership} -> account.email end)
  end

  attr :account, :map, required: true
  attr :membership, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :can_manage_roles, :boolean, default: false
  attr :roles, :list, default: []
  attr :current_account_id, :string, required: true

  defp member_row(assigns) do
    ~H"""
    <tr id={"member-#{@membership.id}"}>
      <td>{@account.email}</td>
      <td>
        <span :if={@membership.role == :owner} class="badge badge-primary">owner</span>
        <div :if={@membership.role != :owner and @can_manage} class="flex items-center gap-2">
          <form phx-change="change-role">
            <input type="hidden" name="membership-id" value={@membership.id} />
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
                selected={to_string(@membership.role) == value}
              >
                {label}
              </option>
            </select>
          </form>
          <form :if={@can_manage_roles and @roles != []} phx-change="assign-custom-role">
            <input type="hidden" name="membership-id" value={@membership.id} />
            <select name="custom-role" class="select select-sm select-bordered" title="Custom role">
              <option value="" selected={@membership.custom_role_id == nil}>
                built-in grants
              </option>
              <option
                :for={role <- @roles}
                value={role.id}
                selected={@membership.custom_role_id == role.id}
              >
                ⚙ {role.name}
              </option>
            </select>
          </form>
        </div>
        <span :if={@membership.role != :owner and not @can_manage} class="badge">
          {@membership.role}
        </span>
      </td>
      <td class="text-sm opacity-70">
        {Calendar.strftime(@membership.inserted_at, "%b %d, %Y")}
      </td>
      <td :if={@can_manage} class="text-right">
        <button
          :if={@membership.role != :owner and @membership.account_id != @current_account_id}
          class="btn btn-ghost btn-xs text-error"
          phx-click="remove-member"
          phx-value-membership-id={@membership.id}
          data-confirm={"Remove #{@account.email} from this workspace?"}
        >
          Remove
        </button>
      </td>
    </tr>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:members}
    >
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
            <tr :if={leaders(@members) != []} class="bg-base-200/40">
              <td colspan="4" class="text-xs uppercase tracking-wide opacity-60 py-1.5">
                <.icon name="hero-shield-check-micro" class="size-3 inline-block mr-1" />
                Owner &amp; admins
              </td>
            </tr>
            <.member_row
              :for={{account, membership} <- leaders(@members)}
              account={account}
              membership={membership}
              can_manage={@can_manage}
              can_manage_roles={@can_manage_roles}
              roles={@roles}
              current_account_id={@current_scope.account.id}
            />
            <tr :if={regulars(@members) != []} class="bg-base-200/40 border-t-2 border-base-300">
              <td colspan="4" class="text-xs uppercase tracking-wide opacity-60 py-1.5">
                Members
              </td>
            </tr>
            <.member_row
              :for={{account, membership} <- regulars(@members)}
              account={account}
              membership={membership}
              can_manage={@can_manage}
              can_manage_roles={@can_manage_roles}
              roles={@roles}
              current_account_id={@current_scope.account.id}
            />
          </tbody>
        </table>
      </div>

      <div :if={@can_manage_roles} class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Custom roles</h2>
        <p class="text-sm opacity-70">
          A custom role grants exactly the checked permissions; assign it to a member in
          the table above (their built-in role stops applying while assigned).
        </p>

        <table :if={@roles != []} class="table table-sm">
          <thead>
            <tr>
              <th>Name</th>
              <th>Permissions</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={role <- @roles} id={"role-#{role.id}"}>
              <td class="font-semibold">{role.name}</td>
              <td class="text-xs opacity-70">{length(role.permissions)} permission(s)</td>
              <td class="text-right">
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete-role"
                  phx-value-role-id={role.id}
                  data-confirm={"Delete role #{role.name}? Assigned members revert to built-in grants."}
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <details class="collapse collapse-arrow border border-base-200">
          <summary class="collapse-title text-sm font-semibold">New custom role</summary>
          <div class="collapse-content">
            <form id="role-form" phx-submit="create-role" class="space-y-3">
              <input
                type="text"
                name="name"
                placeholder="Role name"
                required
                class="input input-bordered input-sm w-64"
              />
              <div :for={{group, permissions} <- permission_groups()} class="space-y-1">
                <p class="text-xs font-semibold opacity-70">{group}</p>
                <div class="grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-1">
                  <label
                    :for={permission <- permissions}
                    class="flex items-center gap-1.5 text-xs"
                  >
                    <input type="hidden" name={"permissions[#{permission}]"} value="false" />
                    <input
                      type="checkbox"
                      name={"permissions[#{permission}]"}
                      value="true"
                      class="checkbox checkbox-xs"
                    />
                    {permission}
                  </label>
                </div>
              </div>
              <button class="btn btn-primary btn-sm">Create role</button>
            </form>
          </div>
        </details>
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
