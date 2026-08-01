defmodule Mix.Tasks.Flux.Demo do
  @shortdoc "Seeds a showcase workspace (echo provider, no credentials needed)"
  @moduledoc """
  Creates `#{Flux.Demo.email()}` with a Demo Workspace: example fluxes
  (branching triage, RAG chatflow, agent with a scratch drive), a
  knowledge base, and published apps — all runnable on the keyless echo
  provider.

      mix flux.demo

  Log in with the demo email via magic link (the dev mailbox at
  /dev/mailbox shows it locally). Refuses to run twice.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Flux.Demo.seed() do
      {:ok, %{workspace: workspace, fluxes: fluxes, apps: apps}} ->
        Mix.shell().info("""
        Great Scott! Seeded "#{workspace.name}":
          fluxes: #{Enum.map_join(fluxes, ", ", & &1.name)}
          apps:   #{Enum.map_join(apps, ", ", & &1.name)}

        Log in as #{Flux.Demo.email()} via magic link (dev mailbox: /dev/mailbox).
        """)

      {:error, :already_seeded} ->
        Mix.shell().error("#{Flux.Demo.email()} already exists — demo data is already seeded.")
    end
  end
end
