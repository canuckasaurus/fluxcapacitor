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
    {"models-and-providers", "Models & providers"},
    {"node-reference", "Node reference"},
    {"apps-and-chat", "Apps & chat"},
    {"knowledge", "Knowledge"},
    {"tools-and-extensions", "Tools & extensions"},
    {"service-api", "Service API"},
    {"operations", "Operations"},
    {"plugin-sdk", "Plugin SDK"}
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

  # The API reference is generated from the OpenAPI spec at runtime (and
  # cached), so it can never drift from what `GET /v1/spec` serves.
  def guides, do: @guides ++ [{"api-reference", "API reference"}]

  # Full-text search index, built at compile time: every h2/h3 section
  # of every guide becomes one searchable entry with its anchor, so a
  # query lands the reader on the exact heading.
  @search_index (for {slug, title} <- @guides,
                     markdown = File.read!(Path.join(@guides_dir, slug <> ".md")),
                     section <- Regex.split(~r/^(?=##+ )/m, markdown),
                     String.trim(section) != "" do
                   {heading, body} =
                     case String.split(section, "\n", parts: 2) do
                       ["#" <> _ = heading_line | rest] ->
                         {String.trim_leading(heading_line, "# "), Enum.join(rest, "\n")}

                       [only] ->
                         {title, only}
                     end

                   anchor =
                     heading
                     |> String.downcase()
                     |> String.replace(~r/[^a-z0-9_]+/, "-")
                     |> String.trim("-")

                   text =
                     body
                     |> String.replace(~r/[`*_#|\[\]()>-]/, " ")
                     |> String.replace(~r/\s+/, " ")
                     |> String.trim()

                   %{
                     slug: slug,
                     guide: title,
                     anchor: anchor,
                     heading: heading,
                     haystack: String.downcase(heading <> " " <> text),
                     snippet: String.slice(text, 0, 180)
                   }
                 end)

  @doc "Sections whose heading or body contain every search term."
  def search(query) do
    terms = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    if terms == [] do
      []
    else
      @search_index
      |> Enum.filter(fn entry -> Enum.all?(terms, &String.contains?(entry.haystack, &1)) end)
      |> Enum.sort_by(fn entry ->
        heading = String.downcase(entry.heading)
        # Heading hits rank above body-only hits.
        {-Enum.count(terms, &String.contains?(heading, &1)), entry.guide}
      end)
      |> Enum.take(12)
    end
  end

  defp resolve(slug) do
    cond do
      slug == "api-reference" -> {"api-reference", {"API reference", api_reference_html()}}
      is_map_key(@rendered, slug) -> {slug, Map.fetch!(@rendered, slug)}
      true -> {"getting-started", Map.fetch!(@rendered, "getting-started")}
    end
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok, assign_guide(socket, params)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_guide(socket, params)}
  end

  defp assign_guide(socket, params) do
    {slug, {title, html}} = resolve(to_string(params["guide"] || ""))

    assign(socket,
      page_title: "Docs — #{title}",
      slug: slug,
      guide_title: title,
      guide_html: html,
      search_query: "",
      search_results: nil
    )
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    results = if String.trim(query) == "", do: nil, else: search(query)
    {:noreply, assign(socket, search_query: query, search_results: results)}
  end

  ## API reference generation

  defp api_reference_html do
    case :persistent_term.get({__MODULE__, :api_reference}, nil) do
      nil ->
        html = build_api_reference()
        :persistent_term.put({__MODULE__, :api_reference}, html)
        html

      html ->
        html
    end
  end

  defp build_api_reference do
    # Round-trip through JSON to get plain maps with resolved $refs.
    spec = FluxWeb.V1.ApiSpec.spec() |> Jason.encode!() |> Jason.decode!()

    endpoint_rows =
      for {path, operations} <- Enum.sort_by(spec["paths"], &elem(&1, 0)),
          {method, op} <- Enum.sort_by(operations, &elem(&1, 0)) do
        {status, response} =
          op["responses"]
          |> Enum.reject(fn {code, _response} -> code == "4XX" end)
          |> List.first() || {"200", %{}}

        schema =
          case get_in(response, ["content", "application/json", "schema", "$ref"]) do
            "#/components/schemas/" <> name -> ~s(<a href="#schema-#{name}">#{name}</a>)
            _none -> "—"
          end

        "<tr><td><code>#{String.upcase(method)}</code></td>" <>
          "<td><code>/v1#{esc(path)}</code></td>" <>
          "<td>#{esc(op["summary"])}</td><td>#{status} → #{schema}</td>" <>
          "<td><details><summary>curl</summary><pre><code>" <>
          esc(curl_example(method, path)) <> "</code></pre></details></td></tr>"
      end

    schema_sections =
      for {name, schema} <- Enum.sort_by(spec["components"]["schemas"], &elem(&1, 0)) do
        required = MapSet.new(schema["required"] || [])

        property_rows =
          for {prop, prop_schema} <- Enum.sort_by(schema["properties"] || %{}, &elem(&1, 0)) do
            badge =
              if MapSet.member?(required, prop),
                do: ~s( <span class="badge badge-ghost badge-xs">required</span>),
                else: ""

            "<tr><td><code>#{esc(prop)}</code>#{badge}</td>" <>
              "<td>#{schema_type(prop_schema)}</td></tr>"
          end

        description =
          case schema["description"] do
            text when is_binary(text) -> "<p>#{esc(text)}</p>"
            _none -> ""
          end

        """
        <h3 id="schema-#{name}">#{esc(name)}</h3>
        #{description}
        <table><thead><tr><th>Field</th><th>Type</th></tr></thead>
        <tbody>#{Enum.join(property_rows)}</tbody></table>
        """
      end

    """
    <h2 id="service-api">Service API reference</h2>
    <p>Generated from the live OpenAPI spec — the raw document is at
    <code>GET /v1/spec</code>. Authenticate with a Bearer token:
    <code>app-…</code> tokens (created on an app's page) drive
    chat/completion endpoints; <code>flux-…</code> tokens (created from
    the canvas API panel) drive workflow, batch, eval, and quality
    endpoints. Errors return the <a href="#schema-Error">Error</a>
    envelope; streaming endpoints accept <code>"response_mode":
    "streaming"</code> and answer <code>text/event-stream</code>.</p>
    <h2 id="endpoints">Endpoints</h2>
    <table><thead><tr><th>Method</th><th>Path</th><th>What it does</th>
    <th>Response</th><th></th></tr></thead>
    <tbody>#{Enum.join(endpoint_rows)}</tbody></table>
    <h2 id="schemas">Schemas</h2>
    #{Enum.join(schema_sections)}
    """
  end

  # Copy-pasteable request per endpoint. Bodies for the well-known POSTs;
  # generic JSON otherwise. $FLUX_TOKEN stands in for app-…/flux-… keys.
  @curl_bodies %{
    "/chat-messages" =>
      ~s({"query": "Hello!", "inputs": {}, "response_mode": "streaming", "user": "abc-123"}),
    "/completion-messages" =>
      ~s({"inputs": {"text": "…"}, "response_mode": "blocking", "user": "abc-123"}),
    "/workflows/run" =>
      ~s({"inputs": {"query": "…"}, "response_mode": "blocking", "user": "abc-123"}),
    "/workflows/batch" => ~s({"rows": [{"query": "first"}, {"query": "second"}]}),
    "/datasets" => ~s({"name": "Handbook"}),
    "/datasets/{id}/document/create-by-text" =>
      ~s({"name": "policy.md", "text": "Refunds within 30 days."}),
    "/datasets/{id}/document/create-by-url" => ~s({"url": "https://example.com/page"}),
    "/datasets/{id}/retrieve" => ~s({"query": "how long do refunds take?", "top_k": 3})
  }

  defp curl_example(method, path) do
    url = "$FLUX_HOST/v1#{String.replace(path, ~r/\{(\w+)\}/, ":\\1")}"
    auth = ~s(-H "Authorization: Bearer $FLUX_TOKEN")

    case String.upcase(method) do
      "GET" ->
        "curl #{auth} \\\n  #{url}"

      "DELETE" ->
        "curl -X DELETE #{auth} \\\n  #{url}"

      _post ->
        body = Map.get(@curl_bodies, path, "{}")

        "curl -X #{String.upcase(method)} #{auth} \\\n" <>
          "  -H \"content-type: application/json\" \\\n" <>
          "  -d '#{body}' \\\n  #{url}"
    end
  end

  defp schema_type(%{"$ref" => "#/components/schemas/" <> name}),
    do: ~s(<a href="#schema-#{name}">#{name}</a>)

  defp schema_type(%{"type" => "array"} = schema),
    do: "array of #{schema_type(schema["items"] || %{})}"

  defp schema_type(%{"enum" => values}) when is_list(values),
    do: esc(Enum.map_join(values, " | ", &inspect/1))

  defp schema_type(%{"type" => type} = schema) do
    nullable = if schema["nullable"], do: " (nullable)", else: ""
    format = if schema["format"], do: " (#{schema["format"]})", else: ""
    "#{type}#{format}#{nullable}"
  end

  defp schema_type(_schema), do: "any"

  defp esc(nil), do: ""

  defp esc(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

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
          <h1 class="text-2xl font-bold">{gettext("Documentation")}</h1>
          <p class="opacity-70 mt-1">{gettext("The guides, right here in the console.")}</p>
        </div>
        <a href={FluxWeb.docs_url()} target="_blank" class="btn btn-ghost btn-sm">
          View on GitHub <.icon name="hero-arrow-top-right-on-square" class="size-3" />
        </a>
      </div>

      <form phx-change="search" id="docs-search" class="w-full max-w-md">
        <input
          type="search"
          name="q"
          value={@search_query}
          placeholder="Search every guide — e.g. business hours, pooling, chunking…"
          class="input input-bordered input-sm w-full"
          autocomplete="off"
          phx-debounce="200"
        />
      </form>

      <div
        :if={@search_results != nil}
        class="card border border-base-200 p-4 space-y-2"
        id="docs-search-results"
      >
        <p :if={@search_results == []} class="text-sm opacity-60">
          Nothing matched — try fewer or different words.
        </p>
        <a
          :for={result <- @search_results || []}
          href={~p"/console/docs/#{result.slug}" <> "#" <> result.anchor}
          class="block rounded-box px-3 py-2 hover:bg-base-200/60"
        >
          <p class="text-sm font-semibold">
            {result.heading}
            <span class="badge badge-ghost badge-xs ml-1">{result.guide}</span>
          </p>
          <p class="text-xs opacity-60">{result.snippet}…</p>
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
