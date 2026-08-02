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
`rss.ex` (datasource + trigger), `llama_index.ex` (tool), and
`notion.ex` / `s3.ex` / `google_drive.ex` (datasources).

### Datasources: Notion, S3, Google Drive

All three sync external documents into knowledge datasets (manually or
on the 5-minute auto-sync cron):

| Plugin | Credentials | What syncs |
|---|---|---|
| `notion` | internal integration token (`ntn_…`) | every page shared with the integration; block rich text flattens to plain text |
| `s3` | bucket, access keys, optional endpoint (MinIO/R2) + prefix | UTF-8 text objects under the prefix; binaries are refused honestly |
| `google_drive` | service-account JSON key + optional folder id | Google Docs (exported as text), Sheets (as CSV), and text files shared with the service account — no OAuth dance |

> Data labeling is **not** a plugin: it's built into the console at
> `/console/labeling` — projects, a tagging queue, CSV intake, relabeling,
> and JSONL export for training code nodes. The app monitor pushes rated
> replies straight into a project.

### LlamaIndex

The `llama_index` tool plugin bridges to an existing LlamaIndex estate —
LlamaCloud (`https://api.cloud.llamaindex.ai`) or any self-hosted
llama_deploy server. Credentials: base URL, API key, and an optional
default pipeline (index) id. Once installed, three functions are
available to tool and agent nodes as the `plugin:llama_index`
pseudo-toolset:

| Operation | What it does |
|---|---|
| `retrieve` | top-k chunks (text + score) from a managed index; `pipeline_id` per call or the credential default |
| `run_workflow` | calls a deployed llama_deploy workflow service as a function (`deployment`, `input` → its result) |
| `list_pipelines` | the account's indexes with their ids — handy for discovery |

So a flux can retrieve from the firm's LlamaIndex indexes, or delegate a
whole step to a LlamaIndex workflow, without migrating anything.
