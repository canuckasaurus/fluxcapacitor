defmodule Flux.PluginRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :flux_plugin_runtime,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Flux.PluginRuntime.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:flux, in_umbrella: true},
      {:flux_plugin, path: "../../packages/flux_plugin"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.15", only: :test}
    ]
  end
end
