defmodule Flux.Accounts.AccountNotifier do
  @moduledoc """
  Delivers account lifecycle emails (magic links, email-change confirmations)
  via `Flux.Mailer`.
  """
  import Swoosh.Email

  alias Flux.Accounts.Account
  alias Flux.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"FluxCapacitor", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver a workspace invitation with its accept link.
  """
  def deliver_invitation_instructions(invitation, workspace, inviter, url) do
    deliver(invitation.email, "You've been invited to #{workspace.name} on FluxCapacitor", """

    ==============================

    Hi #{invitation.email},

    #{inviter.email} invited you to join the "#{workspace.name}" workspace on
    FluxCapacitor as #{invitation.role}.

    Accept the invitation by visiting the URL below (you'll be asked to log in
    or create an account with this email address first):

    #{url}

    This invitation expires on #{Calendar.strftime(invitation.expires_at, "%B %d, %Y")}.
    If you weren't expecting it, please ignore this email.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to update a account email.
  """
  def deliver_update_email_instructions(account, url) do
    deliver(account.email, "Update email instructions", """

    ==============================

    Hi #{account.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(account, url) do
    case account do
      %Account{confirmed_at: nil} -> deliver_confirmation_instructions(account, url)
      _ -> deliver_magic_link_instructions(account, url)
    end
  end

  defp deliver_magic_link_instructions(account, url) do
    deliver(account.email, "Log in instructions", """

    ==============================

    Hi #{account.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(account, url) do
    deliver(account.email, "Confirmation instructions", """

    ==============================

    Hi #{account.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
