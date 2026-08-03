defmodule Flux.RAG.ArangoGraph do
  @moduledoc """
  ArangoDB entity-graph backend (BUSL-1.1 accepted): the Postgres
  entity/mention tables stay the system of record, and each dataset's
  bipartite graph collapses into an entity co-occurrence graph in Arango
  — vertices in `entities`, weighted edges in `cooccurs`. Related-entity
  lookups then run a real 1–2 hop AQL traversal, surfacing second-degree
  neighbors the SQL co-occurrence query can't see.

  Everything is best-effort: `configured?/0` gates all calls, sync
  failures log and fall through, and `related/3` errors fall back to the
  SQL path in `Flux.RAG.related_entities/4`. Tests stub HTTP via
  `req_options`; the `rag` compose profile provides a live server.
  """

  require Logger

  @doc "Whether an Arango server is configured (FLUX_ARANGO_URL)."
  def configured?, do: to_string(config()[:url] || "") != ""

  @doc """
  Rebuilds a dataset's co-occurrence graph from entity/mention rows:
  `entities` holds `{_key, dataset_id, name}` vertices, `cooccurs` holds
  one edge per co-occurring pair with the shared-segment count as
  `weight`. Idempotent — vertices/edges upsert on overwrite.
  """
  def sync_dataset(dataset_id, entities, pairs) do
    with :ok <- ensure_setup() do
      vertices =
        for %{name: name} <- entities do
          %{
            "_key" => vertex_key(dataset_id, name),
            "dataset_id" => dataset_id,
            "name" => name
          }
        end

      edges =
        for {{from_name, to_name}, weight} <- pairs do
          %{
            "_key" => vertex_key(dataset_id, from_name <> "|" <> to_name),
            "_from" => "entities/" <> vertex_key(dataset_id, from_name),
            "_to" => "entities/" <> vertex_key(dataset_id, to_name),
            "dataset_id" => dataset_id,
            "weight" => weight
          }
        end

      with {:ok, _} <- import_documents("entities", vertices),
           {:ok, _} <- import_documents("cooccurs", edges) do
        :ok
      end
    end
  end

  @doc """
  Related entities via a 1..2-hop traversal from the named entity,
  closest and heaviest first. Returns `{:ok, [%{name, weight, depth}]}`
  or `{:error, reason}` (callers fall back to SQL).
  """
  def related(dataset_id, name, limit \\ 10) do
    start = "entities/" <> vertex_key(dataset_id, name)

    query = """
    FOR v, e, p IN 1..2 ANY @start cooccurs
      OPTIONS {uniqueVertices: 'global', order: 'weighted', weightAttribute: 'weight'}
      FILTER v.dataset_id == @dataset_id
      COLLECT name = v.name AGGREGATE weight = SUM(e.weight), depth = MIN(LENGTH(p.edges))
      SORT depth ASC, weight DESC, name ASC
      LIMIT @limit
      RETURN {name: name, weight: weight, depth: depth}
    """

    case cursor(query, %{
           "start" => start,
           "dataset_id" => dataset_id,
           "limit" => limit
         }) do
      {:ok, results} ->
        {:ok,
         for result <- results do
           %{
             name: result["name"],
             weight: result["weight"],
             depth: result["depth"]
           }
         end}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## HTTP plumbing

  # Database + collections are created lazily, once per node (an ETS
  # marker avoids re-asserting on every sync).
  defp ensure_setup do
    if :persistent_term.get({__MODULE__, :setup}, false) do
      :ok
    else
      with {:ok, _} <- request(:post, "/_api/database", %{"name" => database()}, root: true),
           {:ok, _} <- create_collection("entities", 2),
           {:ok, _} <- create_collection("cooccurs", 3) do
        :persistent_term.put({__MODULE__, :setup}, true)
        :ok
      else
        # 409 = already exists — also fine.
        {:error, reason} ->
          Logger.warning("arango setup failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp create_collection(name, type) do
    request(:post, "/_api/collection", %{"name" => name, "type" => type})
  end

  defp import_documents(_collection, []), do: {:ok, %{}}

  defp import_documents(collection, documents) do
    body = Enum.map_join(documents, "\n", &Jason.encode!/1)

    request(
      :post,
      "/_api/import?collection=#{collection}&type=documents&onDuplicate=replace",
      body,
      raw: true
    )
  end

  defp cursor(query, bind_vars) do
    case request(:post, "/_api/cursor", %{"query" => query, "bindVars" => bind_vars}) do
      {:ok, %{"result" => results}} -> {:ok, results}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, path, body, opts \\ []) do
    base = String.trim_trailing(config()[:url], "/")
    db_prefix = if opts[:root], do: "", else: "/_db/#{database()}"

    request_options =
      [
        method: method,
        url: base <> db_prefix <> path,
        auth: {:basic, "root:#{config()[:password]}"},
        receive_timeout: 15_000,
        retry: false
      ] ++
        if opts[:raw],
          # NDJSON, one document per line (Arango's import format).
          do: [body: body, headers: [{"content-type", "application/x-ldjson"}]],
          else: [json: body]

    case Req.request(request_options ++ Application.get_env(:flux, :arango_req_options, [])) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      # Database / collection already there: as good as created.
      {:ok, %{status: 409}} ->
        {:ok, %{}}

      {:ok, %{status: status, body: response}} ->
        {:error, {:http, status, response}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp vertex_key(dataset_id, name) do
    :crypto.hash(:sha256, dataset_id <> ":" <> name)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 27)
  end

  defp database, do: config()[:database] || "flux"
  defp config, do: Application.get_env(:flux, __MODULE__, [])
end
