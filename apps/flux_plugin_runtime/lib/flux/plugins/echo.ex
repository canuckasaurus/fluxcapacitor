defmodule Flux.Plugins.Echo do
  @moduledoc """
  Development/test model provider: streams the last user message back word
  by word. Lets the whole chat pipeline run end-to-end with no API keys.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.Manifest
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec}

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "echo",
      name: "Echo (dev)",
      version: "0.1.0",
      category: :model,
      description: "Streams your message back. For development and demos — no API key needed.",
      credential_schema: []
    }
  end

  @impl Flux.Plugin.ModelProvider
  def models(_credentials) do
    [
      %Spec{name: "echo-1", label: "Echo v1"},
      %Spec{name: "echo-embed", label: "Echo embeddings", type: :text_embedding},
      %Spec{name: "echo-rerank", label: "Echo rerank", type: :rerank}
    ]
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_rerank(_credentials, _model, query, documents) do
    # Deterministic lexical rerank: score = shared distinct words with
    # the query — enough signal for hermetic retrieval tests.
    query_words = words(query)

    scores =
      documents
      |> Enum.with_index()
      |> Enum.map(fn {document, index} ->
        overlap = MapSet.intersection(query_words, words(document)) |> MapSet.size()
        %{index: index, score: overlap / max(MapSet.size(query_words), 1)}
      end)
      |> Enum.sort_by(& &1.score, :desc)

    {:ok, scores}
  end

  defp words(text) do
    text |> String.downcase() |> String.split(~r/\W+/, trim: true) |> MapSet.new()
  end

  @dims 16

  @impl Flux.Plugin.ModelProvider
  def invoke_embeddings(_credentials, _model, texts) do
    # Deterministic bag-of-words vectors: same words → similar vectors, so
    # cosine similarity behaves sensibly in tests without any API.
    vectors =
      for text <- texts do
        text
        |> String.downcase()
        |> String.split(~r/\W+/, trim: true)
        |> Enum.reduce(List.duplicate(0.0, @dims), fn word, acc ->
          index = rem(:erlang.phash2(word), @dims)
          List.update_at(acc, index, &(&1 + 1.0))
        end)
        |> normalize()
      end

    {:ok, %{vectors: vectors, usage: %{input_tokens: 0}}}
  end

  defp normalize(vector) do
    magnitude = :math.sqrt(Enum.reduce(vector, 0.0, &(&2 + &1 * &1)))
    if magnitude == 0.0, do: vector, else: Enum.map(vector, &(&1 / magnitude))
  end

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(_credentials), do: :ok

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(_credentials, request, emit) do
    last_user =
      request.messages
      |> Enum.reverse()
      |> Enum.find_value("(nothing)", fn
        # Vision parity for tests: acknowledge attached images in the echo.
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
      Process.sleep(10)
    end

    {:ok,
     %Result{
       content: reply <> " ",
       finish_reason: :stop,
       usage: %{input_tokens: div(byte_size(last_user), 4), output_tokens: 12}
     }}
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_transcription(_credentials, audio, _opts) do
    {:ok, %{text: "(transcribed #{byte_size(audio)} bytes of audio)"}}
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_speech(_credentials, text, _opts) do
    {:ok, %{audio: "FAKE-MP3:" <> String.slice(text, 0, 50), content_type: "audio/mpeg"}}
  end
end
