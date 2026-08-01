defmodule Flux.PluginRuntime do
  @moduledoc """
  The plugin host facade. Phase A hosts plugins in-node; callers never know
  where a plugin executes, so the Phase-B split to a dedicated BEAM node
  changes nothing outside this module.

  Every invocation runs in a supervised task with a deadline.
  """

  @builtin_plugins [
    Flux.Plugins.OpenAI,
    Flux.Plugins.Anthropic,
    Flux.Plugins.Gemini,
    Flux.Plugins.OpenAICompatible,
    Flux.Plugins.Echo,
    Flux.Plugins.Utility,
    Flux.Plugins.RSS
  ]

  @invoke_timeout :timer.minutes(5)
  @validate_timeout :timer.seconds(30)

  @doc "All registered plugin manifests."
  def list_plugins do
    Enum.map(plugin_modules(), & &1.manifest())
  end

  def list_model_providers do
    Enum.filter(list_plugins(), &(&1.category == :model))
  end

  def list_tool_plugins do
    Enum.filter(list_plugins(), &(&1.category == :tool))
  end

  def tool_operations(plugin_id, credentials) do
    with {:ok, module} <- fetch_plugin(plugin_id) do
      {:ok, module.operations(credentials)}
    end
  end

  def invoke_tool_plugin(plugin_id, credentials, operation_id, args) do
    with {:ok, module} <- fetch_plugin(plugin_id) do
      run_supervised(fn -> module.invoke(credentials, operation_id, args) end, @invoke_timeout)
    end
  end

  def list_datasource_plugins do
    Enum.filter(list_plugins(), &(&1.category == :datasource))
  end

  @doc "Enumerates the documents a datasource currently offers."
  def datasource_documents(plugin_id, credentials) do
    with {:ok, module} <- fetch_plugin(plugin_id) do
      run_supervised(fn -> module.list_documents(credentials) end, @invoke_timeout)
    end
  end

  @doc "Fetches one datasource document's text for indexing."
  def fetch_datasource_document(plugin_id, credentials, doc_id) do
    with {:ok, module} <- fetch_plugin(plugin_id) do
      run_supervised(fn -> module.fetch_document(credentials, doc_id) end, @invoke_timeout)
    end
  end

  @doc "Resolves a plugin module by manifest id."
  def fetch_plugin(plugin_id) do
    case Enum.find(plugin_modules(), &(&1.manifest().id == plugin_id)) do
      nil -> {:error, :unknown_plugin}
      module -> {:ok, module}
    end
  end

  def models(plugin_id, credentials) do
    with {:ok, module} <- fetch_plugin(plugin_id) do
      {:ok, module.models(credentials)}
    end
  end

  def validate_credentials(plugin_id, credentials) do
    with {:ok, module} <- fetch_plugin(plugin_id) do
      run_supervised(fn -> module.validate_credentials(credentials) end, @validate_timeout)
    end
  end

  @doc """
  Invokes an LLM through the plugin. `emit` receives streamed chunks in the
  task's process — it should be a cheap side-effect (send/broadcast), not
  heavy work.
  """
  def invoke_llm(plugin_id, credentials, request, emit) do
    with {:ok, module} <- fetch_plugin(plugin_id) do
      run_supervised(fn -> module.invoke_llm(credentials, request, emit) end, @invoke_timeout)
    end
  end

  @doc "Embeds a batch of texts; {:error, :not_supported} when the plugin has no embedding models."
  def invoke_embeddings(plugin_id, credentials, model, texts) when is_list(texts) do
    with {:ok, module} <- fetch_plugin(plugin_id) do
      if function_exported?(module, :invoke_embeddings, 3) do
        run_supervised(
          fn -> module.invoke_embeddings(credentials, model, texts) end,
          @invoke_timeout
        )
      else
        {:error, :not_supported}
      end
    end
  end

  @doc "Reranks documents against a query; {:error, :not_supported} without the callback."
  def invoke_rerank(plugin_id, credentials, model, query, documents) do
    with {:ok, module} <- fetch_plugin(plugin_id) do
      if function_exported?(module, :invoke_rerank, 4) do
        run_supervised(
          fn -> module.invoke_rerank(credentials, model, query, documents) end,
          @invoke_timeout
        )
      else
        {:error, :not_supported}
      end
    end
  end

  defp run_supervised(fun, timeout) do
    task = Task.Supervisor.async_nolink(Flux.PluginRuntime.TaskSupervisor, fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:plugin_crashed, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp plugin_modules do
    Application.get_env(:flux_plugin_runtime, :plugins, @builtin_plugins)
  end
end
