defmodule Flux.Plugins.Bedrock do
  @moduledoc """
  Amazon Bedrock model provider — Claude models through the Bedrock
  runtime (`POST /model/{id}/invoke`, Anthropic Messages payload with
  `anthropic_version: bedrock-2023-05-31`).

  Requests are SigV4-signed by hand (service `bedrock`) so the plugin
  rides plain Req like every other provider — ExAws has no Bedrock
  service module. Invocation is non-streaming (the streaming endpoint
  uses AWS's binary event-stream framing); the reply text is emitted as
  a single chunk, exactly like an LLM-cache hit.

  Only `anthropic.*` model ids (and `us.`/`eu.`/`apac.` cross-region
  inference profiles of them) are supported.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec, ToolCall}
  alias Flux.Plugins.SSE

  @default_models [
    {"anthropic.claude-3-5-sonnet-20241022-v2:0", "Claude 3.5 Sonnet v2"},
    {"anthropic.claude-3-5-haiku-20241022-v1:0", "Claude 3.5 Haiku"},
    {"anthropic.claude-3-haiku-20240307-v1:0", "Claude 3 Haiku"}
  ]

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "bedrock",
      name: "Amazon Bedrock",
      version: "0.1.0",
      category: :model,
      description: "Claude models via Amazon Bedrock (SigV4, IAM keys).",
      credential_schema: [
        %CredentialField{
          key: "access_key_id",
          label: "Access key id",
          type: :text,
          placeholder: "AKIA…"
        },
        %CredentialField{key: "secret_access_key", label: "Secret access key", type: :secret},
        %CredentialField{
          key: "session_token",
          label: "Session token — optional",
          type: :secret,
          required: false,
          help: "Only for temporary STS credentials."
        },
        %CredentialField{key: "region", label: "Region", type: :text, placeholder: "us-east-1"},
        %CredentialField{
          key: "models",
          label: "Models — optional",
          type: :text,
          required: false,
          placeholder: "anthropic.claude-3-5-sonnet-20241022-v2:0|Claude 3.5 Sonnet",
          help:
            "Comma-separated Bedrock model ids, optionally id|Label. Blank = common Claude ids."
        }
      ]
    }
  end

  @impl Flux.Plugin.ModelProvider
  def models(credentials) do
    configured =
      credentials
      |> Map.get("models", "")
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn entry ->
        case String.split(entry, "|", parts: 2) do
          [name, label] -> %Spec{name: String.trim(name), label: String.trim(label)}
          [name] -> %Spec{name: name, label: name}
        end
      end)

    case configured do
      [] -> for {name, label} <- @default_models, do: %Spec{name: name, label: label}
      specs -> specs
    end
  end

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(credentials) do
    with :ok <- require_fields(credentials) do
      region = region(credentials)
      host = "bedrock.#{region}.amazonaws.com"
      url = "https://#{host}/foundation-models"

      headers = sign(credentials, "GET", host, "/foundation-models", "")

      case Req.get(SSE.req_options(url: url, headers: headers)) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: 403}} -> {:error, "Access denied — check the keys and IAM policy."}
        {:ok, %{status: status}} -> {:error, "Bedrock returned HTTP #{status}."}
        {:error, reason} -> {:error, "Could not reach Bedrock: #{inspect(reason)}"}
      end
    end
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(credentials, request, emit) do
    with :ok <- require_fields(credentials),
         :ok <- require_anthropic(request.model) do
      {system, messages, tools} =
        Flux.Plugins.Anthropic.encode_request(request.messages, request.tools)

      body =
        %{
          anthropic_version: "bedrock-2023-05-31",
          max_tokens: Map.get(request.params, :max_tokens, 4096),
          messages: messages
        }
        |> then(fn body -> if system, do: Map.put(body, :system, system), else: body end)
        |> then(fn body -> if tools == [], do: body, else: Map.put(body, :tools, tools) end)
        |> Map.merge(Map.take(request.params, [:temperature, :top_p]))
        |> Jason.encode!()

      region = region(credentials)
      host = "bedrock-runtime.#{region}.amazonaws.com"
      path = "/model/#{URI.encode(request.model, &URI.char_unreserved?/1)}/invoke"
      headers = sign(credentials, "POST", host, path, body)

      req_opts =
        SSE.req_options(
          url: "https://#{host}#{path}",
          body: body,
          headers: headers,
          receive_timeout: :timer.minutes(5),
          retry: false
        )

      case Req.post(req_opts) do
        {:ok, %{status: 200, body: reply}} -> decode_reply(reply, emit)
        {:ok, %{status: status, body: reply}} -> {:error, {:http_error, status, reply}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode_reply(reply, emit) do
    reply = if is_binary(reply), do: Jason.decode!(reply), else: reply

    content = reply["content"] || []
    text = for %{"type" => "text", "text" => text} <- content, into: "", do: text

    if text != "", do: emit.(%Chunk{delta: text})

    calls =
      for %{"type" => "tool_use"} = block <- content do
        %ToolCall{id: block["id"], name: block["name"], arguments: block["input"] || %{}}
      end

    finish =
      case reply["stop_reason"] do
        "tool_use" -> :tool_calls
        "max_tokens" -> :length
        _other -> :stop
      end

    {:ok,
     %Result{
       content: text,
       finish_reason: finish,
       tool_calls: calls,
       usage: %{
         input_tokens: get_in(reply, ["usage", "input_tokens"]) || 0,
         output_tokens: get_in(reply, ["usage", "output_tokens"]) || 0
       }
     }}
  end

  defp require_fields(credentials) do
    cond do
      to_string(credentials["access_key_id"] || "") == "" ->
        {:error, "Access key id is required."}

      to_string(credentials["secret_access_key"] || "") == "" ->
        {:error, "Secret key is required."}

      to_string(credentials["region"] || "") == "" ->
        {:error, "Region is required."}

      true ->
        :ok
    end
  end

  defp require_anthropic(model) do
    if String.match?(to_string(model), ~r/^([a-z]+\.)?anthropic\./) do
      :ok
    else
      {:error, "the Bedrock plugin supports anthropic.* model ids only (got #{model})"}
    end
  end

  defp region(credentials), do: credentials["region"] |> to_string() |> String.trim()

  # -- SigV4 --------------------------------------------------------------
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
  # Signed headers: host, x-amz-date (+ x-amz-security-token for STS).

  defp sign(credentials, method, host, path, body) do
    region = region(credentials)
    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = Calendar.strftime(now, "%Y%m%d")
    token = to_string(credentials["session_token"] || "")

    payload_hash = hex(:crypto.hash(:sha256, body))

    header_pairs =
      [{"host", host}, {"x-amz-date", amz_date}] ++
        if(token != "", do: [{"x-amz-security-token", token}], else: [])

    canonical_headers = Enum.map_join(header_pairs, "", fn {k, v} -> "#{k}:#{v}\n" end)
    signed_headers = Enum.map_join(header_pairs, ";", &elem(&1, 0))

    canonical_request =
      Enum.join([method, path, "", canonical_headers, signed_headers, payload_hash], "\n")

    scope = "#{date}/#{region}/bedrock/aws4_request"

    string_to_sign =
      Enum.join(
        ["AWS4-HMAC-SHA256", amz_date, scope, hex(:crypto.hash(:sha256, canonical_request))],
        "\n"
      )

    signing_key =
      ("AWS4" <> to_string(credentials["secret_access_key"]))
      |> hmac(date)
      |> hmac(region)
      |> hmac("bedrock")
      |> hmac("aws4_request")

    signature = hex(hmac(signing_key, string_to_sign))

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{credentials["access_key_id"]}/#{scope}, " <>
        "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    [
      {"authorization", authorization},
      {"x-amz-date", amz_date},
      {"content-type", "application/json"}
    ] ++ if(token != "", do: [{"x-amz-security-token", token}], else: [])
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(binary), do: Base.encode16(binary, case: :lower)
end
