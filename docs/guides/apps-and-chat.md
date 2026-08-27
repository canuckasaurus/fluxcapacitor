# Apps & chat

Apps put a product face on models and fluxes: chat UIs, form apps,
public sites, embeds, and a full human-support desk. Manage them at
**Console → Apps**; each app's monitor lives at
`/console/apps/:id/monitor`.

## App modes

| Mode | What it is | Answered by |
|---|---|---|
| `chat` | Multi-turn conversation UI | a provider + model directly |
| `completion` | One-shot form (built from `input_form`) → one answer | a provider + model directly |
| `advanced_chat` (chatflow) | Conversation UI | a published **flux** — every turn runs the graph |

Chat apps carry a system prompt (with a **snippet picker** from the
prompt library), model params, an opening statement, suggested
questions, and optional **follow-up question chips** after each
answer. Chatflows inherit all of it but answer through their bound
flux — the turn's text arrives as `{{sys.query}}`, earlier turns as
`{{sys.history}}`, and `{{conversation.*}}` variables persist across
the conversation.

**Example** — a support chatflow: `start → knowledge_retrieval →
llm → answer` bound to an app gives you a RAG support agent with
citations, publishable as a site in one click.

## Model A/B and prompt A/B

Chat settings can send a share of conversations (stable per
conversation) to a **challenger model** and/or a **B system prompt** —
the monitor compares replies, feedback, and tokens per arm. Fallback
models (single or an ordered chain) take over when the primary errors.

## Publishing: sites, embeds, QR

**Publish as site** mints a stable public URL (`/site/site_…`) —
no login, visitors tracked as anonymous `web_…` refs with their
conversations resumed on return. The site carries the app's
**theme** (accent color, title, logo, custom CSS), OpenGraph tags so
shared links unfurl properly, and optionally:

- **Passcode** — visitors enter it once per browser session (a share
  gate, not authentication).
- **Business hours** — a weekly UTC schedule; outside it the site
  shows your away note, offers a **leave-your-email form**, and stops
  offering "talk to a human".
- **Locked embed origins** — the site's `frame-ancestors` CSP narrows
  from `*` to the origins you list, so the embed only works on your
  domains.

Embed with the **iframe snippet**, the **floating chat-bubble
snippet** (themes itself from the app: color, corner, icon,
greeting), or hand out the **QR code** on the share card — phones
join the chat without typing a URL.

## What a conversation can do

Replies **render markdown** (escape-first, streamed chunks render
live) with copy and regenerate buttons and 👍/👎 feedback (plus an
optional "what was wrong" comment). Visitors and console users can:

- **Attach images and documents** — document text is extracted once
  at upload and rides the model's context; images reach
  vision-capable models.
- **Talk instead of type** — push-to-talk transcribes through the
  provider; every reply has a read-aloud button.
- **Resume, switch, search, rename, and delete** conversations.
- **Download the transcript** (Markdown) or **email it** to the
  address they left.
- **Rate the conversation 1–5** (CSAT) with an optional comment.

Conversations get **model-written titles** after the first exchange,
and long chats stay coherent through **rolling memory** — older turns
fold into a maintained summary instead of overflowing the window.

## The support desk (app monitor)

The monitor is a live support console — new conversations and
messages appear **without a reload**, changed threads carry a "new"
marker, and typing indicators run both ways during handoffs.

**Handoffs.** A visitor clicks *Talk to a human* → the team is
notified (in-console, optionally email/push) and the thread joins
the handoff queue. From there:

- **Claim / assign** — self-claim, or assign any conversation to any
  member; *mine / unassigned* filters keep two humans off one
  visitor. Opt-in **auto-assignment** round-robins new handoffs
  across members marked **Available** (the toggle in the monitor
  header). Being assigned **notifies that member directly** (email +
  browser push) — self-claims stay quiet.
- **Reply as a human** — the visitor sees it live; replies can carry
  **file attachments** (the visitor gets a download chip), insert
  one-click **saved replies** shared by the workspace, or start from
  an **AI draft** ("Draft with AI" — the app's model drafts from
  conversation context, you edit and send; never auto-sent).
- **Read receipts** — "seen HH:MM" once the visitor's open tab has
  the reply.
- **Away-mail** — replying to a visitor who left (and shared an
  email) sends them a heads-up mail with the site link.
- **SLA alert** — a visitor waiting longer than the configured
  minutes fires a notification, once per request (Settings → Failure
  alerts).

**Working the queue.** Threads carry **internal notes** (never shown
to the visitor), **resolve states** (open/resolved filters and 30-day
tallies; a fresh visitor message reopens automatically — and
**auto-resolve** can quietly close threads after N days of visitor
silence, Settings → Failure alerts), **labels** with filters and bulk
operations, and revocable **share links** — read-only transcript
pages for a single conversation. The **Inbox** page
(`/console/inbox`) gathers everything waiting on a human across the
workspace: paused runs with what they're asking, each app's handoff
queue, and the labeling backlog. And the Apps page carries a
**workspace-wide conversation search** — titles and message bodies
across every app, with excerpts, deep-linking into the right
monitor.

**Per-app guardrail scope.** Workspace guardrails apply to every app
by default; an app can **opt out of the pattern checks** (moderation
gates still run — those are workspace policy) or run **extra patterns
of its own** on top — the public marketing bot stricter than the
internal one.

**Quality.** The monitor rolls up usage, feedback and quality trends,
**topic clusters**, per-visitor stats, **CSAT** count + average, and
**conversation evals** (scripted multi-turn dialogues replayed
through the app, LLM-judged, cron-schedulable). Liked replies promote
to **annotations** — canonical answers matched exactly and
embedding-fuzzily before any model call — importable/exportable as
CSV. A **flag button on citations** queues bad retrievals on the
Knowledge page. The GDPR pair: **forget visitor** (hard-deletes a
visitor's conversations, messages, and uploads, audited) and the
visitor's own **transcript download**.

## Chat channels

Beyond the web site, chat rides two inbound channels (App page →
channel cards):

- **Email** — mint a webhook URL (`/channels/email/emch_…`) and point
  a mail provider's inbound route (Mailgun, SES, Postmark) at it.
  Sender + body become a chat turn, one conversation per
  correspondent, and the finished reply is mailed back.
- **Slack** — paste a bot token (`chat:write`, stored encrypted) and
  point the Slack app's Events API at the minted URL
  (`/channels/slack/slch_…`), subscribed to `message.channels` /
  `message.im`. Channel messages become chat turns (one conversation
  per channel + user) and replies post back **threaded**. Bot and
  edited messages are ignored, so it never answers itself; the
  URL-verification handshake is automatic.

Guardrails, quotas, and budgets apply to channel turns like any
other.

**Example** — Slack setup end to end: create a Slack app → add the
`chat:write` bot scope → install to the workspace → paste the
`xoxb-…` token on the app's Slack card → copy the minted URL into
*Event Subscriptions → Request URL* → subscribe to
`message.channels` → invite the bot to a channel. Messages in that
channel now answer in-thread.

## Budgets, quotas, and tokens

Each app can carry a **daily token limit** (past it the API answers
429), a **monthly cost budget** in estimated USD (the team is warned
at 80% and 100%; past it the app answers like a spent daily limit),
and a **per-app rate limit** overriding the pipeline default.

API access: mint `app-…` tokens on the app page — perpetual or
expiring (30/90/365 days), each with expiry + last-used display,
one-click revocation, and an optional per-key rate limit. See the
[service API guide](service-api.md) for the endpoints, and the
webhook events (`conversation.started`, `message.completed`,
`handoff.requested`) for CRM sync without polling.
