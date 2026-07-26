defmodule Flux.Crypto do
  @moduledoc """
  Workspace-scoped envelope encryption for credentials and other secrets.

  Layout: the vault master key (env/KMS) wraps one 256-bit DEK per workspace
  (`workspace_keys`); secrets are AES-256-GCM encrypted with the DEK. Wire
  format: `"v1:" <> Base64(iv <> tag <> ciphertext)`.

  DEKs are cached in Cachex under `{:dek, workspace_id}` with a short TTL so
  rotation propagates without restarts.
  """

  import Ecto.Query

  alias Flux.Crypto.WorkspaceKey
  alias Flux.Repo

  @cache :flux_cache
  @dek_ttl :timer.minutes(10)
  @aad "flux-workspace-secret"

  @doc "Encrypts plaintext for the workspace. Creates the DEK on first use."
  @spec encrypt(Ecto.UUID.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def encrypt(workspace_id, plaintext) when is_binary(plaintext) do
    with {:ok, dek} <- fetch_dek(workspace_id) do
      {:ok, encrypt_with_dek(dek, plaintext)}
    end
  end

  @doc "Decrypts a value produced by `encrypt/2` for the same workspace."
  @spec decrypt(Ecto.UUID.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def decrypt(workspace_id, ciphertext) do
    with {:ok, dek} <- fetch_dek(workspace_id) do
      decrypt_with_dek(dek, ciphertext)
    end
  end

  @doc """
  Rotates the workspace DEK and re-encrypts the given `{id, ciphertext}`
  pairs, returning `{:ok, [{id, new_ciphertext}]}` for the caller to persist.
  (Bulk credential rotation builds on this.)

  DEKs are handled directly here — never through the cache — so this is safe
  to call inside a transaction.
  """
  def rotate_dek(workspace_id, pairs) do
    result =
      Repo.transact(fn ->
        with %WorkspaceKey{dek: old_dek} <-
               Repo.get_by(WorkspaceKey, workspace_id: workspace_id) || {:error, :no_key},
             {:ok, plaintexts} <- decrypt_all(old_dek, pairs) do
          new_dek = :crypto.strong_rand_bytes(32)

          {1, _} =
            from(k in WorkspaceKey, where: k.workspace_id == ^workspace_id)
            |> Repo.update_all(set: [dek: new_dek, updated_at: DateTime.utc_now(:second)])

          {:ok, Enum.map(plaintexts, fn {id, pt} -> {id, encrypt_with_dek(new_dek, pt)} end)}
        end
      end)

    invalidate_cache(workspace_id)
    result
  end

  defp encrypt_with_dek(dek, plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, plaintext, @aad, true)

    "v1:" <> Base.encode64(iv <> tag <> ciphertext)
  end

  defp decrypt_with_dek(dek, "v1:" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, <<iv::binary-12, tag::binary-16, ciphertext::binary>>} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, ciphertext, @aad, tag, false) do
          :error -> {:error, :decryption_failed}
          plaintext -> {:ok, plaintext}
        end

      _ ->
        {:error, :malformed_ciphertext}
    end
  end

  defp decrypt_with_dek(_dek, _other), do: {:error, :malformed_ciphertext}

  defp decrypt_all(dek, pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {id, ciphertext}, {:ok, acc} ->
      case decrypt_with_dek(dek, ciphertext) do
        {:ok, plaintext} -> {:cont, {:ok, [{id, plaintext} | acc]}}
        {:error, reason} -> {:halt, {:error, {id, reason}}}
      end
    end)
  end

  defp fetch_dek(workspace_id) do
    case Cachex.fetch(@cache, {:dek, workspace_id}, fn _ ->
           case load_or_create_dek(workspace_id) do
             {:ok, dek} -> {:commit, dek, expire: @dek_ttl}
             {:error, reason} -> {:ignore, {:error, reason}}
           end
         end) do
      {:ok, dek} when is_binary(dek) -> {:ok, dek}
      {:commit, dek} when is_binary(dek) -> {:ok, dek}
      {:commit, dek, _opts} -> {:ok, dek}
      {:ignore, error} -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_or_create_dek(workspace_id) do
    case Repo.get_by(WorkspaceKey, workspace_id: workspace_id) do
      %WorkspaceKey{dek: dek} ->
        {:ok, dek}

      nil ->
        dek = :crypto.strong_rand_bytes(32)

        %WorkspaceKey{workspace_id: workspace_id, dek: dek}
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: :workspace_id
        )
        |> case do
          {:ok, %{id: nil}} ->
            # Lost the race; read the winner's key.
            {:ok, Repo.get_by!(WorkspaceKey, workspace_id: workspace_id).dek}

          {:ok, key} ->
            {:ok, key.dek}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp invalidate_cache(workspace_id), do: Cachex.del(@cache, {:dek, workspace_id})
end
