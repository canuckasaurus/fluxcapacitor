defmodule FluxWeb.ConsoleLive.Docs do
  @moduledoc """
  In-app documentation: the guides from docs/guides rendered inside the
  console. Markdown converts to HTML at compile time (Earmark — retired
  upstream but pure Elixir, which keeps this box toolchain-free), so the
  release carries the docs with it.
  """
  use FluxWeb, :live_view

  @guides_dir Path.expand("../../../../../../docs/guides", __DIR__)

  @guides [
    {"getting-started", "Getting started"},
    {"node-reference", "Node reference"},
    {"plugin-sdk", "Plugin SDK"},
    {"service-api", "Service API"}
  ]

  for {slug, _title} <- @guides do
    @external_resource Path.join(@guides_dir, slug <> ".md")
  end

  # Slugified ids land on h2/h3 headings so links can anchor into a
  # guide (the canvas docs links target /console/docs/node-reference#llm).
  @anchor_headings fn html ->
    Regex.replace(~r/<(h[23])>(.*?)<\/h[23]>/s, html, fn _full, tag, inner ->
      id =
        inner
        |> String.replace(~r/<[^>]+>/, "")
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_]+/, "-")
        |> String.trim("-")

      ~s(<#{tag} id="#{id}">#{inner}</#{tag}>)
    end)
  end

  @rendered Map.new(@guides, fn {slug, title} ->
              markdown = File.read!(Path.join(@guides_dir, slug <> ".md"))

              html =
                case Earmark.as_html(markdown, gfm: true, breaks: false) do
                  {:ok, html, _warnings} -> html
                  {:error, html, _warnings} -> html
                end

              # Guides reference images relative to docs/guides (GitHub
              # renders those); in the console they serve from /images.
              html = String.replace(html, ~s(src="../images/), ~s(src="/images/))

              {slug, {title, @anchor_headings.(html)}}
            end)

  def guides, do: @guides

  @impl true
  def mount(params, _session, socket) do
    slug =
      case params["guide"] do
        slug when is_map_key(@rendered, slug) -> slug
        _default -> "getting-started"
      end

    {title, html} = Map.fetch!(@rendered, slug)

    {:ok,
     assign(socket,
       page_title: "Docs — #{title}",
       slug: slug,
       guide_title: title,
       guide_html: html
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    slug =
      case params["guide"] do
        slug when is_map_key(@rendered, slug) -> slug
        _default -> "getting-started"
      end

    {title, html} = Map.fetch!(@rendered, slug)

    {:noreply,
     assign(socket,
       page_title: "Docs — #{title}",
       slug: slug,
       guide_title: title,
       guide_html: html
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:docs}
    >
      <div class="flex items-center justify-between flex-wrap gap-2">
        <div>
          <h1 class="text-2xl font-bold">Documentation</h1>
          <p class="opacity-70 mt-1">The guides, right here in the console.</p>
        </div>
        <a href={FluxWeb.docs_url()} target="_blank" class="btn btn-ghost btn-sm">
          View on GitHub <.icon name="hero-arrow-top-right-on-square" class="size-3" />
        </a>
      </div>

      <div class="flex gap-1 flex-wrap">
        <.link
          :for={{slug, title} <- guides()}
          patch={~p"/console/docs/#{slug}"}
          class={[
            "btn btn-sm",
            (@slug == slug && "btn-primary") || "btn-ghost"
          ]}
        >
          {title}
        </.link>
      </div>

      <article class="card border border-base-200 p-8 markdown-prose">
        {Phoenix.HTML.raw(@guide_html)}
      </article>
    </Layouts.console>
    """
  end
end
