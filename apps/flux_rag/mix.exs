defmodule Flux.RAG.MixProject do
  use Mix.Project

  def project do
    [
      app: :flux_rag,
      version: "0.3.0",
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
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:flux, in_umbrella: true},
      {:ecto_sql, "~> 3.13"},
      {:oban, "~> 2.20"},
      {:uuidv7, "~> 1.0"}
    ]
  end
end
