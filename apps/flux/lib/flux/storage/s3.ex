defmodule Flux.Storage.S3 do
  @moduledoc """
  S3-compatible storage adapter. Works against MinIO or AWS S3 — the
  endpoint comes from the standard `:ex_aws, :s3` config, e.g. for MinIO:

      config :ex_aws, :s3,
        scheme: "http://",
        host: "localhost",
        port: 9000

      config :ex_aws,
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        region: "us-east-1"

  Presigned URLs use path-style addressing (`virtual_host: false`), which
  MinIO requires and AWS accepts.
  """
  @behaviour Flux.Storage

  alias ExAws.S3

  @impl true
  def put(key, data) do
    case bucket() |> S3.put_object(key, IO.iodata_to_binary(data)) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key) do
    case bucket() |> S3.get_object(key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case bucket() |> S3.delete_object(key) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(key) do
    match?({:ok, _}, bucket() |> S3.head_object(key) |> ExAws.request())
  end

  @impl true
  def presigned_url(key, opts) do
    expires_in = Keyword.get(opts, :expires_in, 3600)

    :s3
    |> ExAws.Config.new()
    |> S3.presigned_url(:get, bucket(), key,
      expires_in: expires_in,
      virtual_host: false
    )
  end

  defp bucket, do: Keyword.fetch!(Flux.Storage.config(), :bucket)
end
