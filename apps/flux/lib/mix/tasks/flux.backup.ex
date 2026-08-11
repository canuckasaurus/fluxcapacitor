defmodule Mix.Tasks.Flux.Backup do
  @shortdoc "Exports every workspace's archive to a directory"

  @moduledoc """
  Instance-wide disaster-recovery dump: writes each workspace's export
  archive (the same JSON the console's Settings → Export produces) to a
  directory — one file per workspace, named after its id and name.

      mix flux.backup            # ./backups/<today>/
      mix flux.backup /mnt/dr    # a directory of your choosing

  Secrets are never included (same rule as the console export). Exits
  non-zero if any workspace fails, so it slots into cron and deploy
  scripts.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    dir = List.first(args) || Path.join("backups", Date.to_iso8601(Date.utc_today()))
    File.mkdir_p!(dir)

    workspaces = Flux.Repo.all(Flux.Accounts.Workspace)

    results =
      for workspace <- workspaces do
        scope = %Flux.Accounts.Scope{
          workspace: workspace,
          membership: %Flux.Accounts.Membership{workspace_id: workspace.id, role: :owner}
        }

        case Flux.Export.workspace(scope) do
          {:ok, payload} ->
            slug =
              workspace.name
              |> String.downcase()
              |> String.replace(~r/[^a-z0-9]+/, "-")
              |> String.slice(0, 40)

            path = Path.join(dir, "#{slug}-#{String.slice(workspace.id, 0, 8)}.json")
            File.write!(path, Jason.encode!(payload))
            Mix.shell().info("✓ #{workspace.name} → #{path}")
            :ok

          error ->
            Mix.shell().error("✗ #{workspace.name}: #{inspect(error)}")
            :error
        end
      end

    Mix.shell().info(
      "#{Enum.count(results, &(&1 == :ok))}/#{length(results)} workspaces exported to #{dir}"
    )

    if :error in results, do: exit({:shutdown, 1})
  end
end
