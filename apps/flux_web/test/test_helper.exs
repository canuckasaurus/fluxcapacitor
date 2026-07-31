ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Flux.Repo, :manual)
Application.put_env(:flux, :code_runner, Flux.FakeCodeRunner)
