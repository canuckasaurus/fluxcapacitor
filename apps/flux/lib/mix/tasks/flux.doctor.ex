defmodule Mix.Tasks.Flux.Doctor do
  @shortdoc "Checks that everything this install is configured to use is reachable"
  @moduledoc """
  Runs the environment self-check and prints one line per service:

      mix flux.doctor

  `ok` — working; `skipped` — not configured (optional services);
  `FAIL` — configured but unreachable. Exits non-zero on any FAIL,
  so it slots into deploy scripts.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    results = Flux.Doctor.checks()

    for {name, status} <- results do
      case status do
        :ok -> Mix.shell().info("  ok       #{name}")
        :skipped -> Mix.shell().info("  skipped  #{name} (not configured)")
        {:error, detail} -> Mix.shell().error("  FAIL     #{name} — #{detail}")
      end
    end

    if Enum.any?(results, &match?({_name, {:error, _detail}}, &1)) do
      Mix.raise("flux.doctor found failing checks")
    else
      Mix.shell().info("\nGreat Scott — all systems go.")
    end
  end
end
