defmodule Flux.Labeling do
  @moduledoc """
  Bridge to the workspace's Label Studio connector: queue reviewed
  replies (or anything else) as labeling tasks through the
  `label_studio` plugin credentials. The heavy lifting lives in
  `Flux.Plugins.LabelStudio`; this is the console's entry point.
  """

  alias Flux.Accounts.Scope
  alias Flux.Providers
  alias Flux.RBAC

  @doc "Whether the workspace has Label Studio credentials configured."
  def configured?(%Scope{} = scope) do
    match?({:ok, _config}, Providers.fetch_config(Scope.workspace_id(scope), "label_studio"))
  end

  @doc """
  Queues one item as a Label Studio task. `item` is the task's `data`
  map (e.g. `%{"question" => q, "answer" => a}`).
  """
  def queue_item(%Scope{} = scope, item) when is_map(item) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         {:ok, credentials} <- fetch_credentials(scope),
         {:ok, result} <-
           runtime().invoke_tool_plugin("label_studio", credentials, "create_tasks", %{
             "items" => [item]
           }) do
      {:ok, result}
    end
  end

  defp fetch_credentials(scope) do
    case Providers.fetch_config(Scope.workspace_id(scope), "label_studio") do
      {:ok, credentials} -> {:ok, credentials}
      {:error, :not_configured} -> {:error, :not_configured}
    end
  end

  defp runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)
end
