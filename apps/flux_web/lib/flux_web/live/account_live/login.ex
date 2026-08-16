defmodule FluxWeb.AccountLive.Login do
  use FluxWeb, :live_view

  alias Flux.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center space-y-1">
          <div class="flex items-center justify-center gap-2">
            <.icon name="hero-bolt-solid" class="size-8 flux-bolt" />
            <span class="text-3xl flux-wordmark">FluxCapacitor</span>
          </div>
          <p class="text-sm opacity-60">
            <%= if @current_scope do %>
              {gettext("Reauthenticate to perform sensitive account actions.")}
            <% else %>
              {gettext("Log in to your workspace — or")}
              <.link navigate={~p"/accounts/register"} class="link link-primary font-semibold">
                {gettext("create an account")}
              </.link>
            <% end %>
          </p>
        </div>

        <div :if={local_mail_adapter?()} class="alert alert-info text-sm">
          <.icon name="hero-information-circle" class="size-5 shrink-0" />
          <span>
            Local mail adapter: magic links land in <.link href="/dev/mailbox" class="underline">the dev mailbox</.link>.
          </span>
        </div>

        <div class="card border border-base-200 bg-base-100 p-6 space-y-4 shadow-sm">
          <.form
            :let={f}
            for={@form}
            id="login_form_magic"
            action={~p"/accounts/log-in"}
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label={gettext("Email")}
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button class="btn btn-primary w-full">
              {gettext("Log in with email")} <span aria-hidden="true">→</span>
            </.button>
          </.form>

          <div class="divider my-0 text-xs opacity-60">{gettext("or use a password")}</div>

          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/accounts/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label={gettext("Email")}
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label={gettext("Password")}
              autocomplete="current-password"
              spellcheck="false"
            />
            <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
              {gettext("Log in and stay logged in")} <span aria-hidden="true">→</span>
            </.button>
            <.button class="btn btn-primary btn-soft w-full mt-2">
              {gettext("Log in only this time")}
            </.button>
          </.form>

          <div>
            <div class="divider my-0 text-xs opacity-60">or</div>
            <button
              type="button"
              class="btn btn-outline w-full mt-3"
              id="passkey-login"
              phx-hook="PasskeyLogin"
            >
              {gettext("Sign in with a passkey")}
            </button>
            <form
              action={~p"/accounts/passkeys/login"}
              method="post"
              id="passkey-login-form"
              class="hidden"
            >
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <input type="hidden" name="raw_id" />
              <input type="hidden" name="authenticator_data" />
              <input type="hidden" name="signature" />
              <input type="hidden" name="client_data_json" />
            </form>
          </div>

          <div :if={FluxWeb.OIDC.configured?()}>
            <div class="divider my-0 text-xs opacity-60">or</div>
            <.link href={~p"/auth/oidc"} class="btn btn-outline w-full mt-3" id="oidc-login">
              {gettext("Continue with %{provider}", provider: FluxWeb.OIDC.provider_name())}
            </.link>
          </div>
          <div :if={FluxWeb.SAML.configured?()}>
            <.link
              href={"/sso/auth/signin/idp?target_url=#{URI.encode_www_form("/auth/saml/complete")}"}
              class="btn btn-outline w-full mt-3"
              id="saml-login"
            >
              {gettext("Continue with SAML SSO")}
            </.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:account), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "account")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"account" => %{"email" => email}}, socket) do
    if account = Accounts.get_account_by_email(email) do
      Accounts.deliver_login_instructions(
        account,
        &url(~p"/accounts/log-in/#{&1}")
      )
    end

    info =
      gettext(
        "If your email is in our system, you will receive instructions for logging in shortly."
      )

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/accounts/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:flux, Flux.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
