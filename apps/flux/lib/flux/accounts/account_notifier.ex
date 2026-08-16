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
      |> from({"FluxCapacitor", Application.get_env(:flux, :mail_from, "contact@example.com")})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc "Delivers one notification (kind + title) to an opted-in member."
  def deliver_notification_email(recipient, kind, title, path) do
    base = Application.get_env(:flux, :app_base_url, "")
    link = (path && base != "" && "\n\nSee it in the console: #{base}#{path}") || ""

    deliver(recipient, "[FluxCapacitor] #{humanize_kind(kind)}", """

    ==============================

    #{title}#{link}

    You get this email because you opted into "#{kind}" notifications
    in your account settings. Uncheck it there to stop.

    ==============================
    """)
  end

  defp humanize_kind(kind), do: kind |> String.replace("_", " ") |> String.capitalize()

  @doc "Alerts the account that a session just started from an unseen device."
  def deliver_new_device_alert(%Account{} = account, ip, user_agent) do
    deliver(account.email, "[FluxCapacitor] New sign-in to your account", """

    ==============================

    Your account #{account.email} just signed in from a device we
    haven't seen before:

      IP address: #{ip}
      Browser:    #{user_agent || "unknown"}
      Time (UTC): #{DateTime.utc_now(:second) |> DateTime.to_iso8601()}

    If this was you, there's nothing to do. If it wasn't, sign in and
    revoke the session under Account settings → Sessions.

    ==============================
    """)
  end

  @doc "Mails a site visitor that a human replied while they were away."
  def deliver_away_reply(recipient, app_name, excerpt, site_token) do
    base = Application.get_env(:flux, :app_base_url, "")

    link =
      (is_binary(site_token) and base != "" and
         "\n\nPick the conversation back up: " <> base <> "/site/" <> site_token) || ""

    deliver(recipient, "[FluxCapacitor] " <> app_name <> " replied to you", """

    ==============================

    A person replied to your conversation with #{app_name}:

    #{excerpt}#{link}

    You received this because you left your email in the chat.

    ==============================
    """)
  end

  @doc "Mails the model's reply back to an email-channel correspondent."
  def deliver_channel_reply(recipient, app_name, content) do
    deliver(recipient, "Re: your message to " <> app_name, """

    #{content}

    --
    Sent by #{app_name} via FluxCapacitor. Reply to this address to
    continue the conversation.
    """)
  end

  @doc "Mails a chat transcript to the address a site visitor left."
  def deliver_transcript(recipient, app_name, transcript) do
    deliver(recipient, "[FluxCapacitor] Your conversation with #{app_name}", """

    ==============================

    Here is the transcript you asked for:

    #{transcript}

    You received this because you requested a copy of your conversation.

    ==============================
    """)
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
