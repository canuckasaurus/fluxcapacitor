defmodule Flux.Storage.Local do
  @moduledoc """
  Filesystem storage adapter for development and tests. Keys map to paths
  beneath the configured `:local_path`; traversal outside it is rejected.
  """
  @behaviour Flux.Storage

  @impl true
  def put(key, data) do
    path = resolve!(key)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, data)
  end

  @impl true
  def get(key) do
    case File.read(resolve!(key)) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case File.rm(resolve!(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(key), do: File.regular?(resolve!(key))

  @impl true
  def presigned_url(_key, _opts), do: {:error, :unsupported}

  defp resolve!(key) do
    base = Path.expand(Keyword.fetch!(Flux.Storage.config(), :local_path))
    path = Path.expand(Path.join(base, key))

    unless String.starts_with?(path, base <> "/") or String.starts_with?(path, base <> "\\") do
      raise ArgumentError, "storage key escapes the storage root: #{inspect(key)}"
    end

    path
  end
end
