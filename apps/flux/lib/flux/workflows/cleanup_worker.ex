defmodule Flux.Workflows.CleanupWorker do
  @moduledoc """
  Nightly retention sweep (Oban cron, `:cleanup` queue): workspaces with
  `retention_days` in their custom_config lose workflow runs and chat
  messages older than the window. Conversations, audit entries, and
  knowledge stay. Trashed fluxes and apps are purged for everyone after
  #{30} days in the trash.
  """
  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  alias Flux.Repo

  @trash_days 30

  @impl Oban.Worker
  def perform(_job) do
    purge_trash()

    workspaces =
      from(w in Flux.Accounts.Workspace,
        where: fragment("? \\? ?", w.custom_config, "retention_days"),
        select: {w.id, w.custom_config}
      )
      |> Repo.all()

    for {workspace_id, %{"retention_days" => days}} <- workspaces, is_integer(days) do
      cutoff = DateTime.add(DateTime.utc_now(:second), -days, :day)

      {runs_deleted, nil} =
        from(r in Flux.Workflows.WorkflowRun,
          where: r.workspace_id == ^workspace_id and r.inserted_at < ^cutoff,
          where: r.status != :paused
        )
        |> Repo.delete_all()

      {messages_deleted, nil} =
        from(m in Flux.Chat.Message,
          where: m.workspace_id == ^workspace_id and m.inserted_at < ^cutoff,
          where: m.status != :streaming
        )
        |> Repo.delete_all()

      if runs_deleted + messages_deleted > 0 do
        :telemetry.execute(
          [:flux, :retention, :sweep],
          %{runs: runs_deleted, messages: messages_deleted},
          %{workspace_id: workspace_id}
        )
      end
    end

    :ok
  end

  defp purge_trash do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@trash_days, :day)

    from(w in Flux.Workflows.Workflow, where: w.deleted_at < ^cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)

    from(a in Flux.Chat.App, where: a.deleted_at < ^cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)
  end
end
