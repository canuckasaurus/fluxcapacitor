defmodule FluxWeb.AccountLive.Settings do
  use FluxWeb, :live_view

  on_mount {FluxWeb.AccountAuth, :require_sudo_mode}

  alias Flux.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center space-y-1">
        <div class="flex items-center justify-center gap-2">
          <.icon name="hero-bolt-solid" class="size-7 flux-bolt" />
          <span class="text-2xl flux-wordmark">FluxCapacitor</span>
        </div>
        <.header>
          Account settings
          <:subtitle>Manage your email address and password</:subtitle>
        </.header>
        <.link navigate={~p"/console"} class="link link-primary text-sm">
          ← Back to the console
        </.link>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/accounts/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_account_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <div class="space-y-2 text-left" id="email-notifications-card">
        <h2 class="font-semibold">Email notifications</h2>
        <p class="text-sm opacity-70">
          Checked kinds arrive by email as well as in the console feed
          (needs the deployment's SMTP to be configured).
        </p>
        <form phx-change="save_email_kinds" id="email-kinds-form" class="space-y-1">
          <input type="hidden" name="kinds[]" value="" />
          <label
            :for={kind <- Flux.Notifications.kinds()}
            class="flex items-center gap-2 text-sm"
          >
            <input
              type="checkbox"
              name="kinds[]"
              value={kind}
              checked={kind in @email_kinds}
              class="checkbox checkbox-sm"
            /> {String.replace(kind, "_", " ")}
          </label>
        </form>
      </div>

      <div class="divider" />

      <div class="space-y-2 text-left" id="sessions-card">
        <div class="flex items-center justify-between">
          <h2 class="font-semibold">Active sessions</h2>
          <button
            class="btn btn-ghost btn-sm text-error"
            phx-click="revoke_all_sessions"
            data-confirm="Log out everywhere? Every device (including this one) signs out."
          >
            Log out everywhere
          </button>
        </div>
        <div
          :for={token <- @sessions}
          class="flex items-center gap-3 py-2 border-b border-base-200 last:border-0 text-sm"
          id={"session-#{token.id}"}
        >
          <.icon name="hero-computer-desktop" class="size-4 opacity-60" />
          <span>
            Signed in {Calendar.strftime(token.inserted_at, "%b %d, %Y %H:%M")} UTC
            <span :if={token.ip} class="opacity-60">· {token.ip}</span>
            <span :if={token.user_agent} class="opacity-60" title={token.user_agent}>
              · {browser_label(token.user_agent)}
            </span>
          </span>
          <span
            :if={token.token == @current_session_token}
            class="badge badge-primary badge-sm"
          >
            this device
          </span>
          <button
            :if={token.token != @current_session_token}
            class="btn btn-ghost btn-xs text-error ml-auto"
            phx-click="revoke_session"
            phx-value-id={token.id}
            aria-label="Sign out this session"
          >
            Sign out
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_account_email(socket.assigns.current_scope.account, token) do
        {:ok, _account} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/accounts/settings")}
  end

  def mount(_params, session, socket) do
    account = socket.assigns.current_scope.account
    email_changeset = Accounts.change_account_email(account, %{}, validate_unique: false)
    password_changeset = Accounts.change_account_password(account, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, account.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:current_session_token, session["account_token"])
      |> assign(:sessions, Accounts.list_session_tokens(account))
      |> assign(:email_kinds, account.notification_email_kinds || [])
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  defp browser_label(user_agent) do
    cond do
      user_agent =~ "Edg/" -> "Edge"
      user_agent =~ "OPR/" -> "Opera"
      user_agent =~ "Firefox/" -> "Firefox"
      user_agent =~ "Chrome/" -> "Chrome"
      user_agent =~ "Safari/" -> "Safari"
      true -> "browser"
    end
  end

  @impl true
  def handle_event("save_email_kinds", %{"kinds" => kinds}, socket) do
    kinds = Enum.reject(List.wrap(kinds), &(&1 == ""))

    case Accounts.set_notification_email_kinds(socket.assigns.current_scope.account, kinds) do
      {:ok, account} ->
        {:noreply, assign(socket, :email_kinds, account.notification_email_kinds)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the email preferences.")}
    end
  end

  def handle_event("revoke_session", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account
    :ok = Accounts.revoke_session_token(account, id)

    {:noreply,
     socket
     |> put_flash(:info, "That session is signed out.")
     |> assign(:sessions, Accounts.list_session_tokens(account))}
  end

  def handle_event("revoke_all_sessions", _params, socket) do
    :ok = Accounts.revoke_all_session_tokens(socket.assigns.current_scope.account)
    {:noreply, push_navigate(socket, to: ~p"/accounts/log-in")}
  end

  def handle_event("validate_email", params, socket) do
    %{"account" => account_params} = params

    email_form =
      socket.assigns.current_scope.account
      |> Accounts.change_account_email(account_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"account" => account_params} = params
    account = socket.assigns.current_scope.account
    true = Accounts.sudo_mode?(account)

    case Accounts.change_account_email(account, account_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_account_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          account.email,
          &url(~p"/accounts/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"account" => account_params} = params

    password_form =
      socket.assigns.current_scope.account
      |> Accounts.change_account_password(account_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"account" => account_params} = params
    account = socket.assigns.current_scope.account
    true = Accounts.sudo_mode?(account)

    case Accounts.change_account_password(account, account_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
