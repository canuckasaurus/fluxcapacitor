defmodule Flux.Notifications.EmailWorker do
  @moduledoc """
  Delivers a deferred notification email - scheduled at the end of the
  recipient's quiet hours instead of pinging them at 3am.
  """
  # unique so a retry after a partial send (SMTP accepted, response
  # timed out) can't re-enqueue and double-deliver the same notification.
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 3600, fields: [:worker, :args]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email, "kind" => kind, "title" => title} = args}) do
    # Return the delivery result so a genuine failure retries and a
    # success doesn't — the old unconditional `:ok` swallowed both.
    case Flux.Accounts.AccountNotifier.deliver_notification_email(
           email,
           kind,
           title,
           args["path"],
           args["workspace_id"]
         ) do
      {:ok, _email} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
