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
  @notification_days 90
  @delivery_days 30

  @impl Oban.Worker
  def perform(_job) do
    purge_trash()
    sweep_operational_logs()

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

      files_deleted = purge_run_outputs(workspace_id, cutoff)

      if runs_deleted + messages_deleted + files_deleted > 0 do
        :telemetry.execute(
          [:flux, :retention, :sweep],
          %{runs: runs_deleted, messages: messages_deleted, files: files_deleted},
          %{workspace_id: workspace_id}
        )
      end
    end

    :ok
  end

  # Run outputs (filled documents) age out with the same window: the
  # storage object goes first, then the row (and with it the download
  # token). Chat uploads are untouched.
  defp purge_run_outputs(workspace_id, cutoff) do
    files =
      from(f in Flux.Chat.UploadedFile,
        where: f.workspace_id == ^workspace_id and f.inserted_at < ^cutoff,
        where: like(f.key, "run_outputs/%"),
        select: {f.id, f.key}
      )
      |> Repo.all()

    for {_id, key} <- files, do: Flux.Storage.delete(key)

    ids = Enum.map(files, fn {id, _key} -> id end)

    {deleted, nil} =
      from(f in Flux.Chat.UploadedFile,
        where: f.workspace_id == ^workspace_id and f.id in ^ids
      )
      |> Repo.delete_all()

    deleted
  end

  defp purge_trash do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@trash_days, :day)

    from(w in Flux.Workflows.Workflow, where: w.deleted_at < ^cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)

    from(a in Flux.Chat.App, where: a.deleted_at < ^cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)

    from(c in Flux.Chat.Conversation, where: c.deleted_at < ^cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)

    # Trashed datasets purge with their vector index; labeling projects
    # cascade their tasks/votes. Schemaless queries keep flux free of a
    # compile dependency on flux_rag (dependency direction).
    trashed_datasets =
      from(d in "datasets", where: d.deleted_at < ^cutoff, select: d.id)
      |> Repo.all(skip_workspace_guard: true)

    vector_store = Application.get_env(:flux, :vector_store, Flux.RAG.VectorStore.Naive)

    for raw_id <- trashed_datasets do
      {:ok, dataset_id} = Ecto.UUID.load(raw_id)
      apply(vector_store, :drop, [dataset_id])
    end

    from(d in "datasets", where: d.id in ^trashed_datasets)
    |> Repo.delete_all(skip_workspace_guard: true)

    from(p in Flux.Labeling.Project, where: p.deleted_at < ^cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)
  end

  # Operational logs are bounded by age for everyone — they'd otherwise
  # grow without limit regardless of the retention setting.
  defp sweep_operational_logs do
    notification_cutoff = DateTime.add(DateTime.utc_now(:second), -@notification_days, :day)
    delivery_cutoff = DateTime.add(DateTime.utc_now(:second), -@delivery_days, :day)

    from(n in Flux.Notifications.Notification, where: n.inserted_at < ^notification_cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)

    from(d in Flux.Webhooks.Delivery, where: d.inserted_at < ^delivery_cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)
  end
end
