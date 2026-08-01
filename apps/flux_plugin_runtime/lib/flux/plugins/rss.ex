defmodule Flux.Plugins.RSS do
  @moduledoc """
  Built-in datasource plugin: an RSS/Atom feed. Every item becomes a
  document — content comes from the item body (`content:encoded`,
  `description`, or Atom `content`) when present; otherwise the item's
  link is fetched (SSRF-guarded) and stripped to text.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.Datasource
  @behaviour Flux.Plugin.Trigger

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.Datasource.SourceDoc
  alias Flux.Plugins.SSE

  @max_body_bytes 5_000_000

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "rss",
      name: "RSS feed",
      version: "0.1.0",
      category: :datasource,
      capabilities: [:datasource, :trigger],
      description:
        "Sync the items of an RSS/Atom feed into a knowledge dataset, " <>
          "or trigger flux runs when new items appear.",
      credential_schema: [
        %CredentialField{
          key: "feed_url",
          label: "Feed URL",
          type: :url,
          placeholder: "https://example.com/blog.xml"
        }
      ]
    }
  end

  @doc "Credential validation = the feed fetches and contains items."
  def validate_credentials(credentials) do
    case list_documents(credentials) do
      {:ok, _docs} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Flux.Plugin.Datasource
  def list_documents(%{"feed_url" => url}) when is_binary(url) do
    with {:ok, body} <- get(url) do
      case items(body) do
        [] -> {:error, "no <item>/<entry> elements found — is this an RSS/Atom feed?"}
        items -> {:ok, Enum.map(items, &%SourceDoc{id: &1.id, name: &1.title})}
      end
    end
  end

  def list_documents(_credentials), do: {:error, "feed_url is required"}

  @impl Flux.Plugin.Datasource
  def fetch_document(%{"feed_url" => url}, doc_id) when is_binary(url) do
    # Re-read the feed so only documents it currently advertises can be
    # fetched — the doc id never becomes an arbitrary-URL fetch.
    with {:ok, body} <- get(url),
         %{} = item <-
           Enum.find(items(body), &(&1.id == doc_id)) || {:error, "item is not in the feed"} do
      case item.body do
        "" -> fetch_linked_page(item)
        text -> {:ok, %{name: item.title, content: text}}
      end
    end
  end

  def fetch_document(_credentials, _doc_id), do: {:error, "feed_url is required"}

  @impl Flux.Plugin.Trigger
  # First poll (nil cursor) primes on the newest item without replaying
  # history; afterwards every item newer than the cursor is one event.
  # If the cursored item rotated out of the feed, everything replays —
  # acceptable for feeds, and the run inputs make duplicates visible.
  def poll(%{"feed_url" => url}, cursor) when is_binary(url) do
    with {:ok, body} <- get(url) do
      case items(body) do
        [] ->
          {:ok, [], cursor}

        [newest | _rest] when is_nil(cursor) ->
          {:ok, [], newest.id}

        [newest | _rest] = items ->
          events =
            items
            |> Enum.take_while(&(&1.id != cursor))
            # Oldest first, so runs start in publication order.
            |> Enum.reverse()
            |> Enum.map(
              &%{"id" => &1.id, "title" => &1.title, "link" => &1.link, "content" => &1.body}
            )

          {:ok, events, newest.id}
      end
    end
  end

  def poll(_credentials, _cursor), do: {:error, "feed_url is required"}

  defp fetch_linked_page(%{link: ""}), do: {:error, "the item has no content and no link"}

  defp fetch_linked_page(item) do
    with {:ok, body} <- get(item.link) do
      case strip_html(body) do
        "" -> {:error, "the linked page had no readable text"}
        text -> {:ok, %{name: item.title, content: text}}
      end
    end
  end

  ## Feed parsing (regex-based — good enough for well-formed feeds; a
  ## proper XML datasource plugin can replace this without SDK changes)

  defp items(body) do
    ~r/<(item|entry)[\s>].*?<\/\1\s*>/s
    |> Regex.scan(body)
    |> Enum.map(fn [block | _tag] -> parse_item(block) end)
    |> Enum.reject(&(&1.id == ""))
  end

  defp parse_item(block) do
    link = presence(first_tag(block, "link")) || atom_link(block) || ""
    guid = presence(first_tag(block, "guid")) || presence(first_tag(block, "id"))
    title = presence(first_tag(block, "title")) || presence(link) || "untitled"

    body =
      presence(first_tag(block, "content:encoded")) ||
        presence(first_tag(block, "description")) ||
        presence(first_tag(block, "summary")) ||
        presence(first_tag(block, "content")) || ""

    %{id: guid || presence(link) || "", title: title, link: link, body: body}
  end

  defp first_tag(block, tag) do
    escaped = Regex.escape(tag)

    case Regex.run(~r/<#{escaped}(?:\s[^>]*)?>(.*?)<\/#{escaped}\s*>/s, block) do
      [_whole, inner] -> inner |> strip_cdata() |> strip_html()
      nil -> ""
    end
  end

  # Atom link form: <link href="..."/>
  defp atom_link(block) do
    case Regex.run(~r/<link[^>]*href="([^"]+)"/, block) do
      [_whole, href] -> href
      nil -> nil
    end
  end

  defp strip_cdata(text), do: Regex.replace(~r/<!\[CDATA\[(.*?)\]\]>/s, text, "\\1")

  defp strip_html(text) do
    text
    |> String.replace(~r/<(script|style)[\s>].*?<\/\1\s*>/s, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp get(url) do
    with :ok <- Flux.SSRF.verify_url(url),
         {:ok, %{status: 200, body: body}} <-
           Req.get(
             SSE.req_options(
               url: url,
               redirect: false,
               max_retries: 1,
               receive_timeout: 15_000,
               decode_body: false
             )
           ),
         body = to_string(body),
         :ok <- (byte_size(body) <= @max_body_bytes && :ok) || {:error, "response too large"} do
      {:ok, body}
    else
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp presence(""), do: nil
  defp presence(text), do: text
end
