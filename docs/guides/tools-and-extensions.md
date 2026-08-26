# Tools & extensions

Four ways to teach FluxCapacitor new tricks, from zero-code to full
plugin development. Tool and agent nodes mix all of them freely in
one picker.

| Path | Best for | Code needed |
|---|---|---|
| **OpenAPI toolsets** | Any HTTP API as callable tools | none |
| **MCP servers** | Tools an MCP server already exposes | none |
| **Provider instances** | Any OpenAI-shape model endpoint as a provider | none |
| **Plugin SDK** | Deep integrations (providers, datasources, triggers, endpoints) | Elixir |

## OpenAPI toolsets

**Console → Tools** turns any HTTP API into flux tools: paste an
**OpenAPI spec** (JSON or YAML) or **import one from a URL**
(SSRF-guarded), and **every operation in the spec becomes a callable
tool** — in the `tool` node's picker and attachable to agent nodes.

Each toolset stores:

- **Auth** — API keys/headers, encrypted with the workspace key,
  write-only in the UI (a saved secret never renders back).
- **Private variables** — values you template into requests
  (`{{var.tenant_id}}`) without exposing them to the model.

A security summary per toolset shows what auth is set. Agent nodes
attach **several toolsets at once** (colliding operation names are
deduped). When the upstream spec changes, **re-import** the toolset —
one click for URL imports (the source is remembered), or paste the
updated spec — and the operations refresh with an added/removed
count while auth, variables, and every node referencing the toolset
survive.

**Example** — a weather API in three steps: paste its OpenAPI spec →
set `X-Api-Key` under auth → drop a `tool` node, pick
`getForecast`, and template `city: {{start.city}}`. Or attach the
whole toolset to an agent node and let the model pick operations.

## MCP — both directions

**Consume**: *Tools → MCP servers* registers any Model Context
Protocol server (Streamable HTTP; auth headers stored encrypted).
Its tools join the same pickers as toolsets and plugins.

**Serve**: FluxCapacitor is itself an MCP server at `POST /mcp`,
authenticated with a workspace `ws-…` key:

- every **published flux** is advertised as a callable tool (input
  schema derived from its start variables);
- the **prompt library** serves as MCP prompts;
- **dataset documents** serve as MCP resources.

**Example** — Claude Desktop config:

```json
{
  "mcpServers": {
    "fluxcapacitor": {
      "url": "https://your-host/mcp",
      "headers": { "Authorization": "Bearer ws-…" }
    }
  }
}
```

Claude can then run your fluxes and read your knowledge directly.

## Provider instances (custom providers)

Model endpoints aren't tools, but the same "bring your own" spirit
applies: **clone** any credential-taking provider on the Plugins page
into a named instance — ten OpenAI-compatible endpoints coexist as
ten providers, each renameable, each with its own keys and model
catalog. See [Models & providers](models-and-providers.md) for the
full walkthrough.

## Built-in toolsets

- **Images** — providers with an image endpoint put `generate_image`
  in every picker; results land on the Files page.
- **LlamaIndex** — retrieve from LlamaCloud managed indexes or call
  llama_deploy workflow services as functions inside a flux.

## Plugin SDK

When an integration needs real code — a provider with a bespoke wire
format, a datasource, a polled trigger, an HTTP endpoint — the SDK
(`packages/flux_plugin`) defines five behaviours: **model
providers**, **tools**, **datasources**, **triggers**, and
**endpoints**. Plugins are compiled Elixir modules hosted in the
runtime app; installed per workspace, credentials encrypted per
workspace. The [Plugin SDK guide](plugin-sdk.md) walks through each
behaviour with a worked example.

## Which path do I want?

- *"Call our internal REST API from a flux"* → **OpenAPI toolset**
  (paste the spec).
- *"Use the tools our MCP server already has"* → **MCP server**.
- *"Point at a vLLM/Groq/Together endpoint"* → **provider instance**
  of OpenAI-compatible.
- *"Sync documents from a system nobody has a plugin for"* →
  **Plugin SDK**, datasource behaviour.
- *"Fire a flux when something happens elsewhere"* → inbound
  **webhook trigger** (editor → Triggers) if the other side can POST;
  **Plugin SDK** trigger behaviour if it must be polled.
