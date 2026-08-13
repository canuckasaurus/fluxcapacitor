defmodule FluxWeb.AccountLive.Totp do
  @moduledoc """
  The 2FA challenge between password and session: the pending login sits
  in the plug session (`:totp_pending`, set by the session controller),
  this form posts the code back to complete it. A recovery code works in
  the same field.
  """
  use FluxWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center space-y-1">
          <div class="flex items-center justify-center gap-2">
            <.icon name="hero-shield-check" class="size-8 flux-bolt" />
            <span class="text-3xl flux-wordmark">FluxCapacitor</span>
          </div>
          <p class="text-sm opacity-60">
            {gettext("Enter the six-digit code from your authenticator app.")}
          </p>
        </div>

        <div class="card border border-base-200 bg-base-100 p-6 space-y-4 shadow-sm">
          <.form :let={f} for={@form} id="totp_form" action={~p"/accounts/totp"}>
            <.input
              field={f[:code]}
              type="text"
              label={gettext("Authentication code")}
              autocomplete="one-time-code"
              inputmode="numeric"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button class="btn btn-primary w-full">
              {gettext("Verify")} <span aria-hidden="true">→</span>
            </.button>
          </.form>
          <p class="text-xs opacity-60 text-center">
            {gettext("Lost the device? A recovery code works here too.")}
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    case session["totp_pending"] do
      %{"account_id" => _id} ->
        {:ok, assign(socket, form: to_form(%{"code" => ""}, as: "account"))}

      _no_pending_login ->
        {:ok, push_navigate(socket, to: ~p"/accounts/log-in")}
    end
  end
end
