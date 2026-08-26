# Models & providers

Everything about connecting model providers, managing their
credentials, and choosing which models your fluxes and apps run on.
It all lives on **Console → Plugins** unless noted.

## Providers & credentials

FluxCapacitor ships provider plugins for **OpenAI**, **Anthropic**,
**Gemini**, **Azure OpenAI** (endpoint + deployment names), **Amazon
Bedrock** (IAM keys + region, Claude models), **Ollama** (local, zero
config — the model list auto-discovers from whatever `ollama pull`
installed), any **OpenAI-compatible** endpoint (Grok, Together, vLLM,
LM Studio…), and **Echo**, the keyless dev provider that streams your
message back so everything works with no API key.

Click **Configure** on a provider and paste its credentials. They are
**validated against the provider before saving** (a bad key is
rejected on the spot) and stored **encrypted with the workspace key**
— plaintext never touches the database, and secrets are write-only in
the UI.

**Example** — connecting a local vLLM server through the
OpenAI-compatible provider:

```
Base URL:  http://vllm.internal:8000/v1
API key:   (blank — vLLM doesn't need one)
```

Its models then appear in every model picker (LLM nodes, agent nodes,
apps, the playground, evals judges).

## Several keys per provider

One provider can hold **several named keys** ("Add key") — rotate
credentials without downtime by adding the new key, making it default,
then removing the old one. The **default** key is what nodes resolve;
**Test** re-validates any key against the provider on demand (keys
expire between saves, and without the button that only surfaces as
cryptic run failures).

## Key pooling (load balancing)

Flag two or more keys of one provider into the **pool** ("Pool"
button): calls **rotate across pooled keys round-robin** and **fail
over to the next key** on rate limits and provider outages
(429/quota/5xx-shaped errors — bad requests don't retry). Unpooled
setups keep resolving the default key.

**Example**: three OpenAI keys pooled → each chat turn lands on the
next key in rotation; when one key hits its rate limit, the call
retries on the next key instead of failing.

## Provider instances (clone a provider)

Any credential-taking provider can be **cloned** into a named
**instance** — its own credentials, its own model catalog, its own
entry in every model picker. This is how you run **ten
OpenAI-compatible endpoints side by side**, or two Notion workspaces,
or separate staging/production Azure deployments:

1. Click **Clone** on the provider card.
2. Name the instance (`groq-prod`, `local-vllm`, `azure-staging`…).
3. Enter its credentials — validated like any other key.

The instance appears as **its own provider card** (badge: `instance`)
and its models list under the instance's name everywhere. Instances
**rename** freely — the display label changes, the internal id (and
every app or node pointing at it) stays stable. **Remove instance**
deletes its credentials; anything still pointing at it errors until
repointed.

Cloning is also how you create a **custom provider**: clone
`OpenAI-compatible`, point it at any endpoint that speaks the OpenAI
API shape, and name it after the service. No plugin code required.

**Example** — three Groq-hosted models and a local fallback as four
distinct providers:

| Instance | Base URL |
|---|---|
| `groq-us` | `https://api.groq.com/openai/v1` |
| `groq-eu` | `https://eu.api.groq.com/openai/v1` |
| `local-vllm` | `http://vllm.internal:8000/v1` |
| `lm-studio` | `http://127.0.0.1:1234/v1` |

## Per-provider rate caps

Any provider or instance can carry a **requests/minute ceiling**
(the "Rate cap" field on its card): past it, calls refuse with an
honest error instead of stampeding the endpoint — parallel branches,
batches, and busy chats all count against the same bucket. Use it to
protect a low-tier key or a self-hosted server that falls over under
fan-out. The cap is per provider id, so every pooled key shares it
(failover deliberately doesn't dodge it).

## Model allowlist

**Settings → Model allowlist** restricts which provider/model pairs
members can pick: pickers only offer checked models, and app saves
refuse anything else (so a raw API payload can't sneak past the UI).
No boxes checked clears the restriction. Note a restriction is an
explicit list — models added later stay excluded until re-checked.

**Example**: check only `Anthropic — Claude Sonnet` and your
`local-vllm` instance's model — the expensive frontier models
disappear from every picker in the workspace.

## Default model & parameters

**Settings → Default model** picks the workspace default — what LLM
and agent nodes run when their config names no provider, and what
judges, title generation, moderation, and query expansion use.
**Default model params** (temperature, max tokens) apply to every
model call that doesn't set its own.

## Model playground

**Plugins → Playground** races one prompt across up to four models
side by side — latency, tokens, and estimated cost per column — and
one click promotes the winner to workspace default. The cheapest way
to answer "is the expensive model actually better for this?"

## Pricing

Cost estimates come from a built-in price table matched by model-name
prefix (`gpt-4o` prices anything starting with it). Self-hosted and
fine-tuned models read $0 until you add a **price override**
(Settings → Cost controls): model name + USD per million input/output
tokens. Overrides feed every rollup — run costs, dashboards, budgets,
the monthly cost report.

**Example**: `llama-groq | 0.05 | 0.08` prices your Groq Llama at
$0.05/M input and $0.08/M output tokens.

## Provider health

The instance admin panel (`FLUX_ADMIN_EMAILS`) keeps a **per-provider
health table** — calls, errors, and error rate since boot, per
provider *and per instance* — the "is it us or them" view. Chat
falls back automatically when an app names a **fallback model** (one
retry on another provider, recorded on the reply), and fallback
chains extend that to an ordered list.

## Speech, vision, and images

Providers with the matching endpoints automatically unlock:

- **Transcription** (Whisper-shape) — voice input on chats, audio
  documents in knowledge.
- **Text-to-speech** — the read-aloud button uses real provider
  voices when available, browser voices otherwise.
- **Vision** — point an LLM node's `vision_variable` at an uploaded
  image and it rides the prompt to vision-capable models.
- **Text-to-image** — the built-in Images toolset puts
  `generate_image` in every tool and agent picker.
