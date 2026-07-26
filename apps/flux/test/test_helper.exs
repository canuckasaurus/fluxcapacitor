# Core tests use a fake plugin runtime; the real one lives in
# flux_plugin_runtime, which core deliberately does not depend on.
Application.put_env(:flux, :plugin_runtime, Flux.FakeRuntime)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Flux.Repo, :manual)
