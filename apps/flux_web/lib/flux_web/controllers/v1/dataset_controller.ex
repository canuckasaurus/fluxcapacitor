defmodule FluxWeb.V1.DatasetController do
  @moduledoc """
  `/v1/datasets`: list/create/delete datasets, add documents by text or
  URL, list/delete documents, browse segments, and retrieve — any valid
  service token (app- or flux-) operates on its workspace's datasets,
  which makes FluxCapacitor usable as a standalone knowledge API.
  """
  use FluxWeb, :controller

  alias Flux.RAG

  def index(conn, _params) do
    datasets = RAG.list_datasets(conn.assigns.service_scope)

    json(conn, %{
      data:
        for dataset <- datasets do
          %{
            id: dataset.id,
            name: dataset.name,
            description: dataset.description,
            embedding_model: dataset.embedding_model,
            created_at: DateTime.to_unix(dataset.inserted_at)
          }
        end
    })
  end

  def create(conn, %{"name" => name} = params) do
    scope = conn.assigns.service_scope

    {plugin_id, model} = embedding_binding(scope, params)

    case RAG.create_dataset(scope, %{
           "name" => name,
           "description" => params["description"],
           "embedding_plugin_id" => plugin_id,
           "embedding_model" => model
         }) do
      {:ok, dataset} ->
        json(conn, %{id: dataset.id, name: dataset.name})

      {:error, %Ecto.Changeset{} = changeset} ->
        error(conn, 400, "invalid_param", changeset_message(changeset))

      {:error, :unauthorized} ->
        error(conn, 403, "forbidden", "This token cannot manage datasets")
    end
  end

  def create(conn, _params), do: error(conn, 400, "invalid_param", "name is required")

  def create_by_text(conn, %{"id" => dataset_id, "name" => name, "text" => text})
      when is_binary(text) do
    scope = conn.assigns.service_scope

    with dataset when not is_tuple(dataset) <- RAG.get_dataset(scope, dataset_id),
         {:ok, document} <- RAG.add_document(scope, dataset, %{name: name, content: text}) do
      json(conn, %{
        document: %{id: document.id, name: document.name, status: document.status}
      })
    else
      {:error, :not_found} -> error(conn, 404, "not_found", "Dataset not found")
      {:error, :unauthorized} -> error(conn, 403, "forbidden", "This token cannot add documents")
    end
  end

  def create_by_text(conn, _params) do
    error(conn, 400, "invalid_param", "name and text are required")
  end

  def create_by_url(conn, %{"id" => dataset_id, "url" => url}) when is_binary(url) do
    scope = conn.assigns.service_scope

    with dataset when not is_tuple(dataset) <- RAG.get_dataset(scope, dataset_id),
         {:ok, document} <- RAG.add_document_from_url(scope, dataset, url) do
      json(conn, %{
        document: %{id: document.id, name: document.name, status: document.status}
      })
    else
      {:error, :not_found} ->
        error(conn, 404, "not_found", "Dataset not found")

      {:error, :unauthorized} ->
        error(conn, 403, "forbidden", "This token cannot add documents")

      {:error, message} when is_binary(message) ->
        error(conn, 400, "fetch_failed", message)
    end
  end

  def create_by_url(conn, _params), do: error(conn, 400, "invalid_param", "url is required")

  def delete(conn, %{"id" => dataset_id}) do
    scope = conn.assigns.service_scope

    with dataset when not is_tuple(dataset) <- RAG.get_dataset(scope, dataset_id),
         {:ok, _deleted} <- RAG.delete_dataset(scope, dataset) do
      json(conn, %{result: "success"})
    else
      {:error, :not_found} ->
        error(conn, 404, "not_found", "Dataset not found")

      {:error, :unauthorized} ->
        error(conn, 403, "forbidden", "This token cannot delete datasets")
    end
  end

  def delete_document(conn, %{"id" => dataset_id, "document_id" => document_id}) do
    scope = conn.assigns.service_scope

    with {:ok, _document} <- fetch_dataset_document(scope, dataset_id, document_id),
         {:ok, _deleted} <- RAG.delete_document(scope, document_id) do
      json(conn, %{result: "success"})
    else
      {:error, :not_found} ->
        error(conn, 404, "not_found", "Document not found")

      {:error, :unauthorized} ->
        error(conn, 403, "forbidden", "This token cannot delete documents")
    end
  end

  def segments(conn, %{"id" => dataset_id, "document_id" => document_id}) do
    scope = conn.assigns.service_scope

    case fetch_dataset_document(scope, dataset_id, document_id) do
      {:ok, _document} ->
        segments = RAG.list_segments(scope, document_id, 500)

        json(conn, %{
          data:
            for segment <- segments do
              %{
                id: segment.id,
                position: segment.position,
                content: segment.content,
                enabled: segment.enabled
              }
            end
        })

      {:error, :not_found} ->
        error(conn, 404, "not_found", "Document not found")
    end
  end

  # The document must belong to the named dataset (both workspace-scoped).
  defp fetch_dataset_document(scope, dataset_id, document_id) do
    with dataset when not is_tuple(dataset) <- RAG.get_dataset(scope, dataset_id),
         %{} = document <-
           Enum.find(RAG.list_documents(scope, dataset.id), &(&1.id == document_id)) ||
             {:error, :not_found} do
      {:ok, document}
    end
  end

  def documents(conn, %{"id" => dataset_id}) do
    scope = conn.assigns.service_scope

    case RAG.get_dataset(scope, dataset_id) do
      {:error, :not_found} ->
        error(conn, 404, "not_found", "Dataset not found")

      dataset ->
        documents = RAG.list_documents(scope, dataset.id)

        json(conn, %{
          data:
            for document <- documents do
              %{
                id: document.id,
                name: document.name,
                status: document.status,
                segment_count: document.segment_count,
                error: document.error,
                created_at: DateTime.to_unix(document.inserted_at)
              }
            end
        })
    end
  end

  def retrieve(conn, %{"id" => dataset_id, "query" => query}) when is_binary(query) do
    scope = conn.assigns.service_scope
    top_k = parse_top_k(conn.params["top_k"])

    case RAG.retrieve(scope, dataset_id, query, top_k: top_k) do
      {:ok, hits} ->
        json(conn, %{
          query: query,
          records:
            for hit <- hits do
              %{
                segment: %{id: hit.id, content: hit.content, position: hit.position},
                document: %{id: hit.document.id, name: hit.document.name},
                score: hit.score
              }
            end
        })

      {:error, :not_found} ->
        error(conn, 404, "not_found", "Dataset not found")
    end
  end

  def retrieve(conn, _params), do: error(conn, 400, "invalid_param", "query is required")

  defp embedding_binding(scope, params) do
    explicit = {params["embedding_provider"], params["embedding_model"]}

    case explicit do
      {provider, model} when is_binary(provider) and is_binary(model) ->
        {provider, model}

      _fallback ->
        Flux.Providers.available_models(scope)
        |> Enum.find(&(&1.model.type == :text_embedding))
        |> case do
          %{plugin_id: plugin_id, model: model} -> {plugin_id, model.name}
          nil -> {"", ""}
        end
    end
  end

  # nil defers to the dataset's own retrieval settings.
  defp parse_top_k(top_k) when is_integer(top_k) and top_k in 1..20, do: top_k

  defp parse_top_k(top_k) when is_binary(top_k) do
    case Integer.parse(top_k) do
      {n, ""} when n in 1..20 -> n
      _invalid -> nil
    end
  end

  defp parse_top_k(_top_k), do: nil

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{code: code, message: message, status: status})
  end
end
