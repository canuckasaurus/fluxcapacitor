defmodule Flux.Plugins.S3 do
  @moduledoc """
  Built-in datasource plugin: text objects in an S3-compatible bucket
  (AWS, MinIO, R2, …). Objects list under an optional prefix; fetching
  rejects binaries — only valid UTF-8 text ingests into a dataset.

  Rides the app's ExAws + Req stack; a custom `endpoint` is SSRF-checked
  because it is operator-supplied.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.Datasource

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.Datasource.SourceDoc

  @max_keys 200
  @max_object_bytes 5_000_000

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "s3",
      name: "S3 bucket",
      version: "0.1.0",
      category: :datasource,
      capabilities: [:datasource],
      description:
        "Sync text objects from an S3-compatible bucket (AWS, MinIO, R2) " <>
          "into a knowledge dataset.",
      credential_schema: [
        %CredentialField{
          key: "bucket",
          label: "Bucket",
          type: :text,
          placeholder: "my-docs"
        },
        %CredentialField{
          key: "access_key_id",
          label: "Access key id",
          type: :text,
          placeholder: "AKIA…"
        },
        %CredentialField{
          key: "secret_access_key",
          label: "Secret access key",
          type: :secret
        },
        %CredentialField{
          key: "region",
          label: "Region",
          type: :text,
          required: false,
          placeholder: "us-east-1"
        },
        %CredentialField{
          key: "endpoint",
          label: "Endpoint (S3-compatible) — optional",
          type: :url,
          required: false,
          placeholder: "http://minio:9000 — blank for AWS"
        },
        %CredentialField{
          key: "prefix",
          label: "Key prefix — optional",
          type: :text,
          required: false,
          placeholder: "docs/"
        }
      ]
    }
  end

  @doc "Credential validation = one authenticated list round-trip."
  def validate_credentials(credentials) do
    case list_objects(credentials, 1) do
      {:ok, _objects} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Flux.Plugin.Datasource
  def list_documents(credentials) do
    with {:ok, objects} <- list_objects(credentials, @max_keys) do
      docs =
        for object <- objects, not String.ends_with?(object.key, "/") do
          %SourceDoc{id: object.key, name: Path.basename(object.key)}
        end

      case docs do
        [] -> {:error, "no objects under that bucket/prefix"}
        docs -> {:ok, docs}
      end
    end
  end

  @impl Flux.Plugin.Datasource
  def fetch_document(credentials, key) do
    with {:ok, config} <- build_config(credentials),
         {:ok, %{body: body}} <-
           credentials["bucket"]
           |> ExAws.S3.get_object(key)
           |> aws_request(config) do
      cond do
        byte_size(body) > @max_object_bytes ->
          {:error, "object exceeds the #{div(@max_object_bytes, 1_000_000)} MB text cap"}

        not String.valid?(body) or String.contains?(body, <<0>>) ->
          {:error, "object is binary — only UTF-8 text ingests as a document"}

        true ->
          {:ok, %{name: Path.basename(key), content: body}}
      end
    end
  end

  defp list_objects(credentials, max_keys) do
    with {:ok, config} <- build_config(credentials),
         {:ok, %{body: %{contents: contents}}} <-
           credentials["bucket"]
           |> ExAws.S3.list_objects_v2(
             prefix: credentials["prefix"] || "",
             max_keys: max_keys
           )
           |> aws_request(config) do
      {:ok, contents}
    end
  end

  defp aws_request(operation, config) do
    case ExAws.request(operation, config) do
      {:ok, response} ->
        {:ok, response}

      {:error, {:http_error, 403, _body}} ->
        {:error, "access denied (403) — check the keys and bucket policy"}

      {:error, {:http_error, 404, _body}} ->
        {:error, "not found (404) — check the bucket name and key"}

      {:error, {:http_error, status, _body}} ->
        {:error, "the S3 endpoint returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "S3 request failed: #{inspect(reason)}"}
    end
  end

  defp build_config(credentials) do
    bucket = String.trim(credentials["bucket"] || "")
    access_key = String.trim(credentials["access_key_id"] || "")
    secret = credentials["secret_access_key"] || ""

    cond do
      bucket == "" -> {:error, "bucket is required"}
      access_key == "" or secret == "" -> {:error, "access keys are required"}
      true -> endpoint_config(credentials, access_key, secret)
    end
  end

  defp endpoint_config(credentials, access_key, secret) do
    base = [
      access_key_id: access_key,
      secret_access_key: secret,
      region: presence(credentials["region"]) || "us-east-1",
      # Rides Flux.ExAwsHttpClient (Req); tests inject a Req.Test plug here.
      http_opts: [req_opts: Application.get_env(:flux_plugin_runtime, :s3_req_options, [])]
    ]

    case presence(credentials["endpoint"]) do
      nil ->
        {:ok, base}

      endpoint ->
        with :ok <- Flux.SSRF.verify_url(endpoint),
             %URI{scheme: scheme, host: host} = uri when is_binary(host) <- URI.parse(endpoint) do
          {:ok,
           base ++
             [
               scheme: scheme <> "://",
               host: host,
               port: uri.port || if(scheme == "https", do: 443, else: 80)
             ]}
        else
          {:error, message} -> {:error, message}
          _invalid -> {:error, "endpoint must be an http(s) URL"}
        end
    end
  end

  defp presence(nil), do: nil
  defp presence(text) when is_binary(text), do: with("" <- String.trim(text), do: nil)
end
