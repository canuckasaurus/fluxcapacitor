defmodule Flux.Notifications.EmailWorker do
  @moduledoc """
  Delivers a deferred notification email - scheduled at the end of the
  recipient's quiet hours instead of pinging them at 3am.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email, "kind" => kind, "title" => title} = args}) do
    Flux.Accounts.AccountNotifier.deliver_notification_email(
      email,
      kind,
      title,
      args["path"]
    )

    :ok
  end
end
