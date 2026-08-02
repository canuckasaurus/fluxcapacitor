defmodule Flux.Plugins.GoogleDrive do
  @moduledoc """
  Built-in datasource plugin: Google Drive via a **service account** —
  no OAuth dance; paste the service-account JSON key and share the
  folder with the account's email. Google Docs export as plain text,
  Sheets as CSV, and text-like files download directly.

  The JWT-bearer grant is hand-rolled on `:public_key` (RS256) to keep
  the dependency surface flat.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.Datasource

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.Datasource.SourceDoc
  alias Flux.Plugins.SSE

  @drive "https://www.googleapis.com/drive/v3"
  @scope "https://www.googleapis.com/auth/drive.readonly"
  @max_files 100
  @max_body_bytes 5_000_000

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "google_drive",
      name: "Google Drive",
      version: "0.1.0",
      category: :datasource,
      capabilities: [:datasource],
      description:
        "Sync Google Docs, Sheets, and text files from a Drive folder " <>
          "shared with a service account into a knowledge dataset.",
      credential_schema: [
        %CredentialField{
          key: "service_account_json",
          label: "Service account key (JSON)",
          type: :secret,
          placeholder: ~s({"type": "service_account", "client_email": …})
        },
        %CredentialField{
          key: "folder_id",
          label: "Folder id — optional",
          type: :text,
          required: false,
          placeholder: "blank lists everything shared with the account"
        }
      ]
    }
  end

  @doc "Credential validation = mint a token and list one file."
  def validate_credentials(credentials) do
    with {:ok, token} <- access_token(credentials),
         {:ok, _files} <- list_files(credentials, token, 1) do
      :ok
    end
  end

  @impl Flux.Plugin.Datasource
  def list_documents(credentials) do
    with {:ok, token} <- access_token(credentials),
         {:ok, files} <- list_files(credentials, token, @max_files) do
      case Enum.filter(files, &ingestable?/1) do
        [] ->
          {:error, "no ingestable files — share Docs/Sheets/text files with the service account"}

        files ->
          {:ok, Enum.map(files, &%SourceDoc{id: &1["id"], name: &1["name"]})}
      end
    end
  end

  @impl Flux.Plugin.Datasource
  def fetch_document(credentials, file_id) do
    encoded = URI.encode_www_form(file_id)

    with {:ok, token} <- access_token(credentials),
         {:ok, meta} <-
           get_json(token, "#{@drive}/files/#{encoded}?fields=id,name,mimeType"),
         {:ok, content} <- download(token, encoded, meta["mimeType"]) do
      {:ok, %{name: meta["name"], content: content}}
    end
  end

  ## Drive requests

  defp list_files(credentials, token, page_size) do
    query =
      case String.trim(to_string(credentials["folder_id"] || "")) do
        "" -> "trashed=false"
        folder -> "'#{String.replace(folder, "'", "")}' in parents and trashed=false"
      end

    url =
      "#{@drive}/files?" <>
        URI.encode_query(%{
          "q" => query,
          "pageSize" => page_size,
          "fields" => "files(id,name,mimeType)"
        })

    with {:ok, body} <- get_json(token, url) do
      {:ok, List.wrap(body["files"])}
    end
  end

  defp download(token, file_id, "application/vnd.google-apps.document"),
    do: get_text(token, "#{@drive}/files/#{file_id}/export?mimeType=text/plain")

  defp download(token, file_id, "application/vnd.google-apps.spreadsheet"),
    do: get_text(token, "#{@drive}/files/#{file_id}/export?mimeType=text/csv")

  defp download(token, file_id, mime) do
    if text_mime?(mime) do
      get_text(token, "#{@drive}/files/#{file_id}?alt=media")
    else
      {:error, "#{mime} is not ingestable as text"}
    end
  end

  defp ingestable?(%{"mimeType" => mime}) do
    mime in [
      "application/vnd.google-apps.document",
      "application/vnd.google-apps.spreadsheet"
    ] or text_mime?(mime)
  end

  defp text_mime?("text/" <> _subtype), do: true
  defp text_mime?(mime), do: mime in ["application/json", "application/xml", "text/markdown"]

  defp get_json(token, url) do
    case request(token, url) do
      {:ok, %{} = body} -> {:ok, body}
      {:ok, other} when is_binary(other) -> {:ok, Jason.decode!(other)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_text(token, url) do
    case request(token, url) do
      {:ok, body} when is_binary(body) ->
        if String.valid?(body) do
          {:ok, body}
        else
          {:error, "the file is binary — only UTF-8 text ingests as a document"}
        end

      {:ok, body} ->
        {:ok, Jason.encode!(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(token, url) do
    options =
      SSE.req_options(
        url: url,
        headers: [{"authorization", "Bearer " <> token}],
        redirect: false,
        max_retries: 1,
        receive_timeout: 30_000
      )

    case Req.get(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if is_binary(body) and byte_size(body) > @max_body_bytes do
          {:error, "response too large"}
        else
          {:ok, body}
        end

      {:ok, %{status: 401}} ->
        {:error, "Drive rejected the token (401) — check the service-account key"}

      {:ok, %{status: 403}} ->
        {:error, "access denied (403) — is the folder shared with the service account?"}

      {:ok, %{status: status}} ->
        {:error, "Drive returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Drive request failed: #{inspect(reason)}"}
    end
  end

  ## Service-account auth (JWT bearer grant, RS256 via :public_key)

  defp access_token(credentials) do
    with {:ok, account} <- decode_account(credentials),
         {:ok, assertion} <- build_assertion(account) do
      options =
        SSE.req_options(
          url: account["token_uri"] || "https://oauth2.googleapis.com/token",
          form: [
            grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
            assertion: assertion
          ],
          max_retries: 1,
          receive_timeout: 30_000
        )

      case Req.post(options) do
        {:ok, %{status: 200, body: %{"access_token" => token}}} ->
          {:ok, token}

        {:ok, %{status: status, body: body}} ->
          {:error, "token exchange failed (HTTP #{status}): #{token_error(body)}"}

        {:error, reason} ->
          {:error, "token exchange failed: #{inspect(reason)}"}
      end
    end
  end

  defp token_error(%{"error_description" => description}), do: description
  defp token_error(%{"error" => error}), do: error
  defp token_error(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp token_error(_body), do: "no detail"

  defp decode_account(credentials) do
    with raw when raw != "" <- String.trim(to_string(credentials["service_account_json"] || "")),
         {:ok, %{"client_email" => _email, "private_key" => _key} = account} <-
           Jason.decode(raw) do
      {:ok, account}
    else
      "" -> {:error, "service_account_json is required"}
      _invalid -> {:error, "service_account_json must be the full JSON key file"}
    end
  end

  defp build_assertion(account) do
    now = System.os_time(:second)

    header = base64url(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}))

    claims =
      base64url(
        Jason.encode!(%{
          "iss" => account["client_email"],
          "scope" => @scope,
          "aud" => account["token_uri"] || "https://oauth2.googleapis.com/token",
          "iat" => now,
          "exp" => now + 3600
        })
      )

    signing_input = header <> "." <> claims

    with {:ok, key} <- decode_private_key(account["private_key"]) do
      signature = :public_key.sign(signing_input, :sha256, key)
      {:ok, signing_input <> "." <> base64url(signature)}
    end
  end

  defp decode_private_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _rest] ->
        case :public_key.pem_entry_decode(entry) do
          # PKCS#8 wrapper on OTP versions that don't unwrap it themselves.
          {:PrivateKeyInfo, _version, _algorithm, der, _attrs} ->
            {:ok, :public_key.der_decode(:RSAPrivateKey, der)}

          key when is_tuple(key) ->
            {:ok, key}
        end

      [] ->
        {:error, "private_key is not a PEM key"}
    end
  rescue
    _decode_error -> {:error, "private_key could not be decoded"}
  end

  defp decode_private_key(_missing), do: {:error, "private_key is missing from the key file"}

  defp base64url(data), do: Base.url_encode64(data, padding: false)
end
