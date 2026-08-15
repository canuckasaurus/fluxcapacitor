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

        <form phx-submit="save_quiet_hours" id="quiet-hours-form" class="flex gap-2 items-end pt-2">
          <label class="form-control">
            <span class="label-text text-xs opacity-70 mb-1">Quiet from (UTC hour)</span>
            <input
              type="number"
              name="start"
              value={elem(@quiet_hours, 0)}
              min="0"
              max="23"
              placeholder="22"
              class="input input-bordered input-sm w-24"
            />
          </label>
          <label class="form-control">
            <span class="label-text text-xs opacity-70 mb-1">until</span>
            <input
              type="number"
              name="end"
              value={elem(@quiet_hours, 1)}
              min="0"
              max="23"
              placeholder="7"
              class="input input-bordered input-sm w-24"
            />
          </label>
          <button class="btn btn-primary btn-sm">Save quiet hours</button>
          <span class="text-xs opacity-60">
            Emails inside the window defer to its end (feed unaffected). Blank turns it off.
          </span>
        </form>

        <div
          class="flex items-center gap-2 pt-2"
          id="push-card"
          phx-hook="WebPush"
          data-vapid-key={@vapid_public_key}
          data-subscribed={to_string(@push_subscribed)}
        >
          <button type="button" class="btn btn-outline btn-sm" id="push-toggle">
            {(@push_subscribed && "Disable browser notifications") || "Enable browser notifications"}
          </button>
          <span class="text-xs opacity-60">
            Handoff requests and run failures reach this browser even with the console closed.
          </span>
        </div>
      </div>

      <div class="divider" />

      <div class="space-y-2 text-left" id="totp-card">
        <h2 class="font-semibold">Two-factor authentication</h2>

        <div :if={@totp_enabled and @totp_recovery_codes == []} class="space-y-2">
          <p class="text-sm">
            <.icon name="hero-shield-check" class="size-4 text-success inline" />
            2FA is on — login asks for a code from your authenticator app.
          </p>
          <button
            class="btn btn-ghost btn-sm text-error"
            phx-click="disable_totp"
            data-confirm="Turn off two-factor authentication?"
          >
            Turn off 2FA
          </button>
        </div>

        <div :if={@totp_recovery_codes != []} class="space-y-2">
          <p class="text-sm font-semibold text-success">
            2FA is on. Save these recovery codes now — each works once and
            they won't be shown again:
          </p>
          <pre id="totp-recovery-codes" class="rounded-box bg-base-200 p-3 text-xs">{Enum.join(@totp_recovery_codes, "\n")}</pre>
        </div>

        <div :if={!@totp_enabled and @totp_enrollment == nil}>
          <p class="text-sm opacity-70 mb-2">
            Add a second factor: your password plus a six-digit code from
            an authenticator app.
          </p>
          <button class="btn btn-primary btn-sm" phx-click="start_totp">
            Set up 2FA
          </button>
        </div>

        <div :if={@totp_enrollment != nil} class="space-y-2">
          <p class="text-sm opacity-70">
            Scan this with your authenticator app, then enter the code it
            shows to finish:
          </p>
          <div class="bg-white p-2 rounded-box w-fit">{raw(@totp_enrollment.qr_svg)}</div>
          <p class="text-xs opacity-60 break-all">
            Manual entry: <code>{@totp_enrollment.secret_base32}</code>
          </p>
          <form phx-submit="confirm_totp" id="confirm-totp-form" class="flex gap-2 items-center">
            <input
              type="text"
              name="code"
              placeholder="123456"
              autocomplete="one-time-code"
              inputmode="numeric"
              class="input input-bordered input-sm w-32"
              required
            />
            <button class="btn btn-primary btn-sm">Confirm</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_totp">
              Cancel
            </button>
          </form>
        </div>
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
      |> assign(:quiet_hours, {account.quiet_hours_start, account.quiet_hours_end})
      |> assign(:totp_enabled, Accounts.totp_enabled?(account))
      |> assign(:push_subscribed, Flux.WebPush.subscribed?(account))
      |> assign(:vapid_public_key, Flux.WebPush.vapid_public_key())
      |> assign(:totp_enrollment, nil)
      |> assign(:totp_recovery_codes, [])
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
  def handle_event("save_quiet_hours", %{"start" => start_text, "end" => end_text}, socket) do
    parse = fn text ->
      case Integer.parse(to_string(text)) do
        {hour, ""} when hour in 0..23 -> hour
        _blank_or_invalid -> nil
      end
    end

    {start_hour, end_hour} =
      case {parse.(start_text), parse.(end_text)} do
        {start_hour, end_hour} when is_integer(start_hour) and is_integer(end_hour) ->
          {start_hour, end_hour}

        _partial_or_blank ->
          {nil, nil}
      end

    case Accounts.set_quiet_hours(socket.assigns.current_scope.account, start_hour, end_hour) do
      {:ok, account} ->
        info =
          (start_hour && "Quiet hours saved: #{start_hour}:00–#{end_hour}:00 UTC.") ||
            "Quiet hours off."

        {:noreply,
         socket
         |> put_flash(:info, info)
         |> assign(quiet_hours: {account.quiet_hours_start, account.quiet_hours_end})}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save quiet hours.")}
    end
  end

  def handle_event("push_subscribed", %{"subscription" => subscription}, socket) do
    case Flux.WebPush.subscribe(socket.assigns.current_scope.account, subscription) do
      {:ok, _subscription} ->
        {:noreply,
         socket
         |> put_flash(:info, "Browser notifications enabled.")
         |> assign(push_subscribed: true)}

      {:error, _invalid} ->
        {:noreply, put_flash(socket, :error, "Could not store the push subscription.")}
    end
  end

  def handle_event("push_unsubscribed", %{"endpoint" => endpoint}, socket) do
    :ok = Flux.WebPush.unsubscribe(socket.assigns.current_scope.account, endpoint)

    {:noreply,
     socket
     |> put_flash(:info, "Browser notifications disabled.")
     |> assign(push_subscribed: false)}
  end

  def handle_event("push_error", %{"reason" => reason}, socket) do
    {:noreply,
     put_flash(socket, :error, "Browser notifications unavailable: " <> to_string(reason))}
  end

  def handle_event("save_email_kinds", %{"kinds" => kinds}, socket) do
    kinds = Enum.reject(List.wrap(kinds), &(&1 == ""))

    case Accounts.set_notification_email_kinds(socket.assigns.current_scope.account, kinds) do
      {:ok, account} ->
        {:noreply, assign(socket, :email_kinds, account.notification_email_kinds)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the email preferences.")}
    end
  end

  def handle_event("start_totp", _params, socket) do
    account = socket.assigns.current_scope.account
    true = Accounts.sudo_mode?(account)
    {account, uri} = Accounts.init_totp(account)

    {:noreply,
     assign(socket, :totp_enrollment, %{
       account: account,
       qr_svg: uri |> EQRCode.encode() |> EQRCode.svg(width: 180),
       secret_base32: Base.encode32(account.totp_secret, padding: false)
     })}
  end

  def handle_event("confirm_totp", %{"code" => code}, socket) do
    case Accounts.confirm_totp(socket.assigns.totp_enrollment.account, code) do
      {:ok, _account, recovery_codes} ->
        {:noreply,
         assign(socket,
           totp_enabled: true,
           totp_enrollment: nil,
           totp_recovery_codes: recovery_codes
         )}

      {:error, _invalid} ->
        {:noreply, put_flash(socket, :error, "That code didn't match — try the next one.")}
    end
  end

  def handle_event("cancel_totp", _params, socket) do
    Accounts.disable_totp(socket.assigns.totp_enrollment.account)
    {:noreply, assign(socket, totp_enrollment: nil)}
  end

  def handle_event("disable_totp", _params, socket) do
    account = socket.assigns.current_scope.account
    true = Accounts.sudo_mode?(account)
    Accounts.disable_totp(account)

    {:noreply,
     socket
     |> put_flash(:info, "Two-factor authentication is off.")
     |> assign(totp_enabled: false, totp_recovery_codes: [])}
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
