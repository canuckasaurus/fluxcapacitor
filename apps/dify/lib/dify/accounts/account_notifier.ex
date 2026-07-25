defmodule Dify.Accounts.AccountNotifier do
  @moduledoc """
  Delivers account lifecycle emails (magic links, email-change confirmations)
  via `Dify.Mailer`.
  """
  import Swoosh.Email

  alias Dify.Accounts.Account
  alias Dify.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Dify", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
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
