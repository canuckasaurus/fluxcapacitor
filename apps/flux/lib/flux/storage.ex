defmodule Flux.Storage do
  @moduledoc """
  Object storage facade. The backend is a config toggle:

      # config/runtime.exs (env-driven)
      config :flux, Flux.Storage,
        backend: :s3,                # or :local
        bucket: "fluxcapacitor",
        local_path: "/var/lib/flux/storage"

  `:s3` speaks the S3 API and works against MinIO or AWS alike — point
  `:ex_aws, :s3` at the MinIO endpoint (see `Flux.Storage.S3`). `:local`
  writes beneath `local_path` and is the dev/test default.

  Keys are plain strings; callers are responsible for prefixing them with
  the owning workspace id (e.g. `"workspaces/\#{id}/uploads/\#{file_id}"`).
  """

  @type key :: String.t()

  @callback put(key, iodata()) :: :ok | {:error, term()}
  @callback get(key) :: {:ok, binary()} | {:error, :not_found} | {:error, term()}
  @callback delete(key) :: :ok | {:error, term()}
  @callback exists?(key) :: boolean()
  @callback presigned_url(key, opts :: keyword()) ::
              {:ok, String.t()} | {:error, :unsupported} | {:error, term()}

  def put(key, data), do: adapter().put(key, data)
  def get(key), do: adapter().get(key)
  def delete(key), do: adapter().delete(key)
  def exists?(key), do: adapter().exists?(key)

  @doc """
  A time-limited direct-download URL. Supported by the `:s3` backend
  (`expires_in` seconds, default 3600); the `:local` backend returns
  `{:error, :unsupported}` — serve those through the web layer instead.
  """
  def presigned_url(key, opts \\ []), do: adapter().presigned_url(key, opts)

  def config, do: Application.fetch_env!(:flux, __MODULE__)

  defp adapter do
    case Keyword.fetch!(config(), :backend) do
      :local -> Flux.Storage.Local
      :s3 -> Flux.Storage.S3
      other -> raise ArgumentError, "unknown storage backend #{inspect(other)}"
    end
  end
end
