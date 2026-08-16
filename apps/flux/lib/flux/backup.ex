defmodule Flux.Backup do
  @moduledoc """
  Scheduled disaster-recovery dumps: the same per-workspace export
  archives `mix flux.backup` writes to disk, pushed nightly through
  `Flux.Storage` (S3 in production) under `backups/<date>/…`. Opt-in
  via `FLUX_SCHEDULED_BACKUPS=true`; the once-a-day gate lives in
  instance settings so restarts don't double-run it.
  """

  require Logger

  @doc "Whether nightly storage backups are enabled for this instance."
  def enabled? do
    Application.get_env(:flux, :scheduled_backups, false) == true
  end

  @doc """
  Ticked by the scheduler: after 03:00 UTC, once per calendar day, dump
  every workspace's export archive to storage. Returns `:ok` (skipped
  or ran); individual workspace failures are logged, never fatal.
  """
  def run_scheduled(now \\ DateTime.utc_now(:second)) do
    today = now |> DateTime.to_date() |> Date.to_iso8601()

    if enabled?() and now.hour >= 3 and Flux.InstanceSettings.get("backup_last_date") != today do
      Flux.InstanceSettings.put("backup_last_date", today)
      run_to_storage(today)
    end

    :ok
  end

  @doc "Writes every workspace's archive to storage under backups/<label>/."
  def run_to_storage(label) do
    workspaces = Flux.Repo.all(Flux.Accounts.Workspace)

    results =
      for workspace <- workspaces do
        scope = %Flux.Accounts.Scope{
          workspace: workspace,
          membership: %Flux.Accounts.Membership{workspace_id: workspace.id, role: :owner}
        }

        slug =
          workspace.name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.slice(0, 40)

        key = "backups/#{label}/#{slug}-#{String.slice(workspace.id, 0, 8)}.json"

        with {:ok, payload} <- Flux.Export.workspace(scope),
             :ok <- Flux.Storage.put(key, Jason.encode!(payload)) do
          :ok
        else
          error ->
            Logger.warning("backup failed for workspace #{workspace.id}: #{inspect(error)}")
            :error
        end
      end

    ok = Enum.count(results, &(&1 == :ok))
    Logger.info("nightly backup: #{ok}/#{length(results)} workspaces → backups/#{label}/")
    {:ok, %{ok: ok, failed: length(results) - ok}}
  end
end
