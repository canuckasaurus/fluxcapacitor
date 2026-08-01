# Plugin SDK

A plugin is an Elixir module implementing `Flux.Plugin` (a manifest)
plus one or more capability behaviours from `packages/flux_plugin`. The
runtime hosts every invocation in a supervised task with a deadline;
callers never know where a plugin executes.

```elixir
defmodule MyOrg.Plugins.Weather do
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.Tool

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.Tool.Operation

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "weather",
      name: "Weather",
      version: "0.1.0",
      category: :tool,
      credential_schema: [
        %CredentialField{key: "api_key", label: "API key", type: :secret}
      ]
    }
  end

  @impl Flux.Plugin.Tool
  def operations(_credentials) do
    [%Operation{id: "current", name: "current_weather",
      description: "Current weather for a city",
      parameters: %{"type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]}}]
  end

  @impl Flux.Plugin.Tool
  def invoke(credentials, "current", %{"city" => city}) do
    {:ok, %{text: "Sunny in #{city}", data: %{}}}
  end
end
```

Register it (dev/self-hosted) by adding the module to
`config :flux_plugin_runtime, :plugins, [...]`.

## The five behaviours

| Behaviour | Contract | The platform then |
|---|---|---|
| `Flux.Plugin.ModelProvider` | `models/1`, `validate_credentials/1`, `invoke_llm/3` (+ optional `invoke_embeddings/3`, `invoke_rerank/4`) | offers the models everywhere, streams chunks, embeds datasets, reranks retrieval |
| `Flux.Plugin.Tool` | `operations/1`, `invoke/3` | shows the plugin as a `plugin:<id>` toolset in tool and agent nodes once installed |
| `Flux.Plugin.Datasource` | `list_documents/1`, `fetch_document/2` | syncs documents into datasets, manually or on a per-dataset interval |
| `Flux.Plugin.Trigger` | `poll/2` (cursor-based) | polls on the minute tick; every returned event starts one published run |
| `Flux.Plugin.Endpoint` | `handle_request/2` | serves HTTP at `/e/:installation-token/*path` with the workspace's credentials |

One module may implement several behaviours — the built-in RSS plugin is
a datasource *and* a trigger; Utilities is a tool *and* an endpoint.

## Credentials & installation

- **Model providers and datasources** store credentials through the
  Plugins page: validated by `validate_credentials/1`, encrypted with
  the workspace key, decrypted only at call time. Multiple named keys
  per plugin are supported; the default resolves.
- **Tools/datasources/triggers/endpoints** must be *installed* per
  workspace (Plugins page). Installation mints the endpoint token.

## Built-ins as reference implementations

`apps/flux_plugin_runtime/lib/flux/plugins/` — `openai.ex` /
`anthropic.ex` / `gemini.ex` (streaming SSE, tool calls, vision),
`openai_compatible.ex` (any base URL), `echo.ex` (deterministic
chat/embed/rerank for CI and demos), `utility.ex` (tool + endpoint),
`rss.ex` (datasource + trigger).
