defmodule Flux.FakeRuntime do
  @moduledoc """
  Test double for `Flux.PluginRuntime` used by core (`apps/flux`) tests —
  the real runtime lives in an app core doesn't depend on. Mirrors the Echo
  provider's observable behaviour; flux_web tests exercise the real runtime.
  """

  alias Flux.Plugin.Manifest
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec}

  @echo %Manifest{
    id: "echo",
    name: "Echo (dev)",
    version: "0.1.0",
    category: :model,
    credential_schema: []
  }

  @openai %Manifest{
    id: "openai",
    name: "OpenAI",
    version: "0.1.0",
    category: :model,
    credential_schema: [
      %Flux.Plugin.CredentialField{key: "api_key", label: "API key"}
    ]
  }

  @slow_echo %Manifest{
    id: "slow_echo",
    name: "Slow Echo (dev)",
    version: "0.1.0",
    category: :model,
    credential_schema: []
  }

  @drip %Manifest{
    id: "drip",
    name: "Drip (dev)",
    version: "0.1.0",
    category: :model,
    credential_schema: []
  }

  def list_plugins, do: [@echo, @openai, @slow_echo, @drip]
  def list_model_providers, do: [@echo, @openai, @slow_echo, @drip]

  def models("echo", _credentials), do: {:ok, [%Spec{name: "echo-1", label: "Echo v1"}]}
  def models("slow_echo", _credentials), do: {:ok, [%Spec{name: "echo-1", label: "Echo v1"}]}
  def models("drip", _credentials), do: {:ok, [%Spec{name: "echo-1", label: "Echo v1"}]}
  def models("openai", _credentials), do: {:ok, [%Spec{name: "gpt-4o", label: "GPT-4o"}]}
  def models(_other, _credentials), do: {:error, :unknown_plugin}

  def validate_credentials("echo", _), do: :ok
  def validate_credentials("slow_echo", _), do: :ok
  def validate_credentials("drip", _), do: :ok
  def validate_credentials("openai", %{"api_key" => "sk-valid"}), do: :ok
  def validate_credentials("openai", _), do: {:error, "Invalid API key."}

  def validate_credentials("label_studio", %{"api_token" => token})
      when is_binary(token) and token != "",
      do: :ok

  def validate_credentials("label_studio", _), do: {:error, "api_token is required"}
  def validate_credentials(_other, _), do: {:error, :unknown_plugin}

  def invoke_llm("echo", _credentials, request, emit) do
    last_user =
      request.messages
      |> Enum.reverse()
      |> Enum.find_value("(nothing)", fn
        %{role: :user, content: content} = message ->
          case Map.get(message, :images, []) do
            [] -> content
            images -> "#{content} [#{length(images)} image(s)]"
          end

        _ ->
          nil
      end)

    reply = "You said: #{last_user}"

    for word <- String.split(reply, " ") do
      emit.(%Chunk{delta: word <> " "})
    end

    {:ok, %Result{content: reply <> " ", usage: %{input_tokens: 3, output_tokens: 12}}}
  end

  # Sleeps mid-invocation so tests can exercise stopping an in-flight run.
  def invoke_llm("slow_echo", credentials, request, emit) do
    Process.sleep(:timer.seconds(5))
    invoke_llm("echo", credentials, request, emit)
  end

  # Emits a prefix, then hangs — for testing that stop preserves streamed text.
  def invoke_llm("drip", _credentials, _request, emit) do
    emit.(%Chunk{delta: "Dripped "})
    emit.(%Chunk{delta: "prefix"})
    Process.sleep(:timer.seconds(5))
    {:ok, %Result{content: "never finished", usage: %{input_tokens: 1, output_tokens: 1}}}
  end

  def invoke_llm(_other, _credentials, _request, _emit), do: {:error, :unknown_plugin}

  # Deterministic bag-of-words vectors, mirroring the real Echo plugin so
  # retrieval tests get meaningful cosine similarity without any API.
  @embed_dims 16

  def invoke_embeddings("echo", _credentials, _model, texts) do
    vectors =
      for text <- texts do
        text
        |> String.downcase()
        |> String.split(~r/\W+/, trim: true)
        |> Enum.reduce(List.duplicate(0.0, @embed_dims), fn word, acc ->
          index = rem(:erlang.phash2(word), @embed_dims)
          List.update_at(acc, index, &(&1 + 1.0))
        end)
        |> normalize()
      end

    {:ok, %{vectors: vectors, usage: %{input_tokens: 0}}}
  end

  def invoke_embeddings(_other, _credentials, _model, _texts), do: {:error, :not_supported}

  def invoke_rerank("echo", _credentials, _model, query, documents) do
    query_words = query |> String.downcase() |> String.split(~r/\W+/, trim: true) |> MapSet.new()

    scores =
      documents
      |> Enum.with_index()
      |> Enum.map(fn {document, index} ->
        document_words =
          document |> String.downcase() |> String.split(~r/\W+/, trim: true) |> MapSet.new()

        overlap = MapSet.intersection(query_words, document_words) |> MapSet.size()
        %{index: index, score: overlap / max(MapSet.size(query_words), 1)}
      end)
      |> Enum.sort_by(& &1.score, :desc)

    {:ok, scores}
  end

  def invoke_rerank(_other, _credentials, _model, _query, _documents),
    do: {:error, :not_supported}

  ## Tool plugins (mirrors the real utility plugin's surface)

  def list_tool_plugins do
    [%{id: "utility", name: "Utilities", category: :tool, credential_schema: []}]
  end

  def tool_operations("utility", _credentials) do
    {:ok,
     [
       %{
         id: "current_time",
         name: "current_time",
         description: "UTC now",
         parameters: %{"type" => "object", "properties" => %{}}
       }
     ]}
  end

  def tool_operations(_other, _credentials), do: {:error, :unknown_plugin}

  def invoke_tool_plugin("utility", _credentials, "current_time", _args) do
    {:ok, %{text: DateTime.to_iso8601(DateTime.utc_now(:second)), data: %{}}}
  end

  def invoke_tool_plugin("label_studio", _credentials, "create_tasks", args) do
    count = length(List.wrap(args["items"]))
    {:ok, %{text: "queued #{count} tasks for labeling", data: %{"task_count" => count}}}
  end

  def invoke_tool_plugin(_plugin, _credentials, _operation, _args),
    do: {:error, :unknown_plugin}

  defp normalize(vector) do
    magnitude = :math.sqrt(Enum.reduce(vector, 0.0, &(&2 + &1 * &1)))
    if magnitude == 0.0, do: vector, else: Enum.map(vector, &(&1 / magnitude))
  end
end
