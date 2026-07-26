defmodule Flux.PluginRuntime.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Flux.PluginRuntime.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Flux.PluginRuntime.Supervisor)
  end
end
