defmodule Flux.Plugins.Notion do
  @moduledoc """
  Built-in datasource plugin: Notion pages via an internal integration
  token. `list_documents` searches every page shared with the
  integration; `fetch_document` reads the page's block children and
  flattens their rich text. Share pages with the integration in Notion
  (Connections → your integration) or nothing will be listed.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.Datasource

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.Datasource.SourceDoc
  alias Flux.Plugins.SSE

  @base "https://api.notion.com/v1"
  @notion_version "2022-06-28"
  @max_pages 100
  @max_block_requests 10

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "notion",
      name: "Notion",
      version: "0.1.0",
      category: :datasource,
      capabilities: [:datasource],
      description:
        "Sync Notion pages shared with an internal integration into a knowledge dataset.",
      credential_schema: [
        %CredentialField{
          key: "api_token",
          label: "Integration token",
          type: :secret,
          placeholder: "ntn_… (Notion → Settings → Connections → Develop or manage integrations)"
        }
      ]
    }
  end

  @doc "Credential validation = one authenticated search round-trip."
  def validate_credentials(credentials) do
    case search_pages(credentials, 1) do
      {:ok, _pages} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Flux.Plugin.Datasource
  def list_documents(credentials) do
    with {:ok, pages} <- search_pages(credentials, @max_pages) do
      case pages do
        [] -> {:error, "no pages found — share pages with the integration in Notion"}
        pages -> {:ok, Enum.map(pages, &%SourceDoc{id: &1["id"], name: page_title(&1)})}
      end
    end
  end

  @impl Flux.Plugin.Datasource
  def fetch_document(credentials, page_id) do
    with {:ok, page} <- request(credentials, :get, "/pages/#{page_id}", nil),
         {:ok, blocks} <- fetch_blocks(credentials, page_id) do
      case blocks |> Enum.map(&block_text/1) |> Enum.reject(&(&1 == "")) do
        [] -> {:error, "the page has no readable text blocks"}
        texts -> {:ok, %{name: page_title(page), content: Enum.join(texts, "\n")}}
      end
    end
  end

  defp search_pages(credentials, limit) do
    body = %{
      "filter" => %{"property" => "object", "value" => "page"},
      "page_size" => min(limit, 100)
    }

    with {:ok, %{"results" => results}} <- request(credentials, :post, "/search", body) do
      {:ok, Enum.filter(results, &(&1["object"] == "page"))}
    end
  end

  # Paginates /blocks/:id/children, bounded so a pathological page can't
  # spin the sync worker.
  defp fetch_blocks(credentials, page_id, cursor \\ nil, acc \\ [], requests \\ 0)

  defp fetch_blocks(_credentials, _page_id, _cursor, acc, @max_block_requests),
    do: {:ok, Enum.reverse(acc)}

  defp fetch_blocks(credentials, page_id, cursor, acc, requests) do
    path =
      "/blocks/#{page_id}/children?page_size=100" <>
        if(cursor, do: "&start_cursor=#{URI.encode_www_form(cursor)}", else: "")

    with {:ok, %{"results" => results} = response} <- request(credentials, :get, path, nil) do
      acc = Enum.reduce(results, acc, &[&1 | &2])

      if response["has_more"] && response["next_cursor"] do
        fetch_blocks(credentials, page_id, response["next_cursor"], acc, requests + 1)
      else
        {:ok, Enum.reverse(acc)}
      end
    end
  end

  defp page_title(page) do
    page
    |> get_in(["properties"])
    |> Kernel.||(%{})
    |> Map.values()
    |> Enum.find_value(fn
      %{"type" => "title", "title" => title} -> plain_text(title)
      _other -> nil
    end)
    |> case do
      nil -> "untitled"
      "" -> "untitled"
      title -> title
    end
  end

  defp block_text(%{"type" => type} = block) do
    case block[type] do
      %{"rich_text" => rich_text} -> plain_text(rich_text)
      %{"title" => title} when is_binary(title) -> title
      _other -> ""
    end
  end

  defp block_text(_block), do: ""

  defp plain_text(rich_text) when is_list(rich_text) do
    Enum.map_join(rich_text, "", &(&1["plain_text"] || ""))
  end

  defp plain_text(_other), do: ""

  # The host is the fixed Notion API — no user-supplied URL, so no SSRF
  # surface; auth failures get a pointed message.
  defp request(credentials, method, path, body) do
    token = String.trim(credentials["api_token"] || "")

    if token == "" do
      {:error, "api_token is required"}
    else
      options =
        SSE.req_options(
          method: method,
          url: @base <> path,
          headers: [
            {"authorization", "Bearer " <> token},
            {"notion-version", @notion_version}
          ],
          receive_timeout: 30_000,
          retry: false
        )

      options = if body, do: Keyword.put(options, :json, body), else: options

      case Req.request(options) do
        {:ok, %{status: status, body: %{} = decoded}} when status in 200..299 ->
          {:ok, decoded}

        {:ok, %{status: 401}} ->
          {:error, "Notion rejected the token (401) — check the integration token"}

        {:ok, %{status: 404}} ->
          {:error, "not found — is the page shared with the integration?"}

        {:ok, %{status: status, body: body}} ->
          {:error, "Notion returned HTTP #{status}: #{extract_message(body)}"}

        {:error, reason} ->
          {:error, "Notion request failed: #{inspect(reason)}"}
      end
    end
  end

  defp extract_message(%{"message" => message}) when is_binary(message), do: message
  defp extract_message(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp extract_message(_body), do: "no detail"
end
