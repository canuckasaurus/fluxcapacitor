ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Flux.Repo, :manual)
Application.put_env(:flux, :code_runner, Flux.FakeCodeRunner)

# Umbrella `mix test` runs every app's suite in one VM; the flux suite
# swaps in its FakeRuntime, so pin the real plugin runtime back for the
# end-to-end web tests (echo provider, embeddings, SSE).
Application.put_env(:flux, :plugin_runtime, Flux.PluginRuntime)
