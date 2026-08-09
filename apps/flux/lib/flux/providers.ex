defmodule Flux.Providers do
  @moduledoc """
  Model-provider configuration per workspace: which plugins have credentials,
  and which models those unlock. Credentials are encrypted with the
  workspace DEK (`Flux.Crypto`); plaintext never touches the database.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Crypto
  alias Flux.Providers.ProviderCredential
  alias Flux.RBAC
  alias Flux.Repo

  # Resolved at call time so core never compile-depends on the runtime app
  # (dependency direction: plugin_runtime -> core), and tests can inject a
  # fake with Application.put_env(:flux, :plugin_runtime, Fake).
  defp runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

  @doc """
  One playground call: the prompt against one provider/model, timed and
  costed. Returns `{:ok, %{content, latency_ms, input_tokens,
  output_tokens, cost_usd}}` or `{:error, reason}`.
  """
  def playground_run(workspace_id, plugin_id, model, prompt) do
    credentials =
      case fetch_config(workspace_id, plugin_id) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    request = %Flux.Plugin.ModelProvider.Request{
      model: model,
      messages: [%{role: :user, content: prompt}],
      params: %{}
    }

    {elapsed_us, result} =
      :timer.tc(fn ->
        runtime().invoke_llm(plugin_id, credentials, request, fn _chunk -> :ok end)
      end)

    case result do
      {:ok, reply} ->
        input = reply.usage.input_tokens
        output = reply.usage.output_tokens

        cost =
          case Flux.Pricing.estimate(workspace_id, model, input, output) do
            {:ok, cost} -> cost
            :unknown -> nil
          end

        {:ok,
         %{
           content: reply.content,
           latency_ms: div(elapsed_us, 1000),
           input_tokens: input,
           output_tokens: output,
           cost_usd: cost
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "One embeddings call with the workspace's credentials (OpenAI-compat API)."
  def embed(workspace_id, plugin_id, model, texts) when is_list(texts) do
    credentials =
      case fetch_config(workspace_id, plugin_id) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    runtime().invoke_embeddings(plugin_id, credentials, model, texts)
  end

  @doc """
  Transcribes audio through the workspace default model's provider
  (audio documents in knowledge). `{:error, :not_supported}` when no
  default is set or the provider has no speech-to-text.
  """
  def transcribe(workspace_id, audio, opts \\ %{}) when is_binary(audio) do
    case default_model_for_workspace(workspace_id) do
      %{"provider_plugin_id" => plugin_id} when is_binary(plugin_id) and plugin_id != "" ->
        credentials =
          case fetch_config(workspace_id, plugin_id) do
            {:ok, config} -> config
            {:error, :not_configured} -> %{}
          end

        runtime().invoke_transcription(plugin_id, credentials, audio, opts)

      _no_default ->
        {:error, :not_supported}
    end
  end

  @doc """
  Generates an image through the workspace default model's provider
  (the `builtin:images` tool). `opts` may carry `"model"` and `"size"`.
  `{:error, :not_supported}` when no default is set or the provider has
  no image endpoint.
  """
  def generate_image(workspace_id, prompt, opts \\ %{}) when is_binary(prompt) do
    case default_model_for_workspace(workspace_id) do
      %{"provider_plugin_id" => plugin_id} when is_binary(plugin_id) and plugin_id != "" ->
        credentials =
          case fetch_config(workspace_id, plugin_id) do
            {:ok, config} -> config
            {:error, :not_configured} -> %{}
          end

        invoke_opts =
          %{}
          |> then(&(((m = presence(opts["model"])) && Map.put(&1, :model, m)) || &1))
          |> then(&(((s = presence(opts["size"])) && Map.put(&1, :size, s)) || &1))

        runtime().invoke_image(plugin_id, credentials, prompt, invoke_opts)

      _no_default ->
        {:error, :not_supported}
    end
  end

  @doc "All model-provider plugin manifests known to the runtime."
  def list_provider_plugins, do: runtime().list_model_providers()

  @doc "Credentials configured in the scope's workspace (config stays encrypted)."
  def list_credentials(%Scope{} = scope) do
    ProviderCredential
    |> Repo.scoped(scope)
    |> order_by([c], asc: c.plugin_id)
    |> Repo.all()
  end

  @doc """
  Saves (upserts) named credentials for a plugin after validating them
  against the provider. Requires the `plugin_model_config` permission.
  Several named credentials can coexist per plugin (key rotation without
  downtime); the first one for a plugin becomes the default.
  """
  def upsert_credential(%Scope{} = scope, plugin_id, config, name \\ "default")
      when is_map(config) do
    workspace_id = Scope.workspace_id(scope)
    name = presence(name) || "default"

    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         :ok <- validate_with_plugin(plugin_id, config),
         {:ok, encrypted} <- Crypto.encrypt(workspace_id, Jason.encode!(config)),
         {:ok, credential} <-
           %ProviderCredential{}
           |> ProviderCredential.changeset(%{
             workspace_id: workspace_id,
             plugin_id: plugin_id,
             name: name,
             encrypted_config: encrypted,
             validated_at: DateTime.utc_now(:second)
           })
           |> Repo.insert(
             on_conflict: {:replace, [:encrypted_config, :validated_at, :updated_at]},
             conflict_target: [:workspace_id, :plugin_id, :name]
           ) do
      ensure_default(workspace_id, plugin_id)

      Flux.Audit.record(scope, "provider.credential_upsert",
        resource_type: "provider_credential",
        resource_id: plugin_id,
        metadata: %{"name" => name}
      )

      {:ok, credential}
    end
  end

  @doc "Makes the credential the one `fetch_config/2` resolves for its plugin."
  def set_default_credential(%Scope{} = scope, credential_id) do
    workspace_id = Scope.workspace_id(scope)

    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         %ProviderCredential{} = credential <-
           Repo.one(Repo.scoped(where(ProviderCredential, id: ^credential_id), scope)) ||
             {:error, :not_found} do
      Repo.transaction(fn ->
        from(c in ProviderCredential,
          where: c.workspace_id == ^workspace_id and c.plugin_id == ^credential.plugin_id
        )
        |> Repo.update_all(set: [is_default: false])

        from(c in ProviderCredential,
          where: c.workspace_id == ^workspace_id and c.id == ^credential.id
        )
        |> Repo.update_all(set: [is_default: true])
      end)

      Flux.Audit.record(scope, "provider.default_credential_set",
        resource_type: "provider_credential",
        resource_id: credential.id,
        metadata: %{"plugin_id" => credential.plugin_id, "name" => credential.name}
      )

      :ok
    end
  end

  # Every plugin with credentials keeps exactly one default (oldest wins
  # when none is flagged — covers first inserts and default deletion).
  defp ensure_default(workspace_id, plugin_id) do
    default_exists =
      from(c in ProviderCredential,
        where:
          c.workspace_id == ^workspace_id and c.plugin_id == ^plugin_id and c.is_default == true
      )
      |> Repo.exists?()

    unless default_exists do
      from(c in ProviderCredential,
        where: c.workspace_id == ^workspace_id and c.plugin_id == ^plugin_id,
        order_by: [asc: c.inserted_at, asc: c.id],
        limit: 1,
        select: c.id
      )
      |> Repo.one()
      |> case do
        nil ->
          :ok

        id ->
          from(c in ProviderCredential, where: c.workspace_id == ^workspace_id and c.id == ^id)
          |> Repo.update_all(set: [is_default: true])
      end
    end

    :ok
  end

  defp presence(nil), do: nil

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def delete_credential(%Scope{} = scope, credential_id) do
    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         %ProviderCredential{} = credential <-
           Repo.one(Repo.scoped(where(ProviderCredential, id: ^credential_id), scope)) ||
             {:error, :not_found},
         {:ok, deleted} <- Repo.delete(credential) do
      # Deleting the default promotes the oldest survivor.
      ensure_default(credential.workspace_id, credential.plugin_id)

      Flux.Audit.record(scope, "provider.credential_delete",
        resource_type: "provider_credential",
        resource_id: credential.plugin_id,
        metadata: %{"name" => credential.name}
      )

      {:ok, deleted}
    end
  end

  @doc """
  Decrypted credential config for a plugin, or `{:error, :not_configured}`.
  With several named credentials, the default one wins (oldest as a
  tiebreak for rows predating the default flag).
  """
  def fetch_config(workspace_id, plugin_id) do
    query =
      from(c in ProviderCredential,
        where: c.workspace_id == ^workspace_id and c.plugin_id == ^plugin_id,
        order_by: [desc: c.is_default, asc: c.inserted_at, asc: c.id],
        limit: 1
      )

    with %ProviderCredential{} = credential <- Repo.one(query) || {:error, :not_configured},
         {:ok, json} <- Crypto.decrypt(workspace_id, credential.encrypted_config) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  Models available to the workspace: every configured plugin's catalog, plus
  keyless plugins (empty credential schema, e.g. the Echo dev provider).
  """
  def available_models(%Scope{} = scope) do
    workspace_id = Scope.workspace_id(scope)
    configured = MapSet.new(list_credentials(scope), & &1.plugin_id)

    for manifest <- list_provider_plugins(),
        manifest.credential_schema == [] or MapSet.member?(configured, manifest.id),
        # Config-driven catalogs (e.g. openai_compatible) need the stored
        # credentials to know which models they offer.
        config =
          (case fetch_config(workspace_id, manifest.id) do
             {:ok, config} -> config
             _not_configured -> %{}
           end),
        {:ok, models} = runtime().models(manifest.id, config),
        model <- models do
      %{plugin_id: manifest.id, plugin_name: manifest.name, model: model}
    end
  end

  @doc """
  Embeds texts with a workspace-configured provider. Returns
  `{:ok, [[float]]}` in input order.
  """
  def embed_texts(workspace_id, plugin_id, model, texts) when is_list(texts) do
    # Deterministic outputs cache per text — only misses hit the provider.
    keyed =
      for text <- texts do
        key = Flux.EmbeddingCache.key(plugin_id, model, text)

        case Flux.EmbeddingCache.get(key) do
          {:ok, vector} -> {:hit, vector}
          :miss -> {:miss, key, text}
        end
      end

    misses = for {:miss, key, text} <- keyed, do: {key, text}

    with {:ok, fresh} <- embed_uncached(workspace_id, plugin_id, model, misses) do
      fresh_by_key =
        for {{key, _text}, vector} <- Enum.zip(misses, fresh), into: %{} do
          Flux.EmbeddingCache.put(key, vector)
          {key, vector}
        end

      vectors =
        for entry <- keyed do
          case entry do
            {:hit, vector} -> vector
            {:miss, key, _text} -> Map.fetch!(fresh_by_key, key)
          end
        end

      {:ok, vectors}
    end
  end

  defp embed_uncached(_workspace_id, _plugin_id, _model, []), do: {:ok, []}

  defp embed_uncached(workspace_id, plugin_id, model, misses) do
    credentials =
      case fetch_config(workspace_id, plugin_id) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    texts = Enum.map(misses, fn {_key, text} -> text end)

    case runtime().invoke_embeddings(plugin_id, credentials, model, texts) do
      {:ok, %{vectors: vectors}} -> {:ok, vectors}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reranks documents against a query with a workspace-configured provider."
  def rerank_texts(workspace_id, plugin_id, model, query, documents) do
    credentials =
      case fetch_config(workspace_id, plugin_id) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    runtime().invoke_rerank(plugin_id, credentials, model, query, documents)
  end

  ## Default model (workspace-level system model)

  @doc """
  Sets the workspace default model, used by LLM/agent nodes whose config
  names no provider. Requires `plugin_model_config`. Pass empty strings
  to clear it.
  """
  def set_default_model(%Scope{} = scope, plugin_id, model) do
    with :ok <- RBAC.authorize(scope, :plugin_model_config) do
      workspace = Repo.get!(Flux.Accounts.Workspace, Scope.workspace_id(scope))

      default =
        if plugin_id in [nil, ""] or model in [nil, ""] do
          nil
        else
          %{"provider_plugin_id" => plugin_id, "model" => model}
        end

      custom_config =
        if default do
          Map.put(workspace.custom_config || %{}, "default_model", default)
        else
          Map.delete(workspace.custom_config || %{}, "default_model")
        end

      with {:ok, updated} <-
             workspace
             |> Ecto.Changeset.change(custom_config: custom_config)
             |> Repo.update() do
        Flux.Audit.record(scope, "provider.default_model_set",
          resource_type: "workspace",
          resource_id: workspace.id,
          metadata: default || %{"cleared" => true}
        )

        {:ok, updated}
      end
    end
  end

  @doc "The workspace default model as `%{\"provider_plugin_id\", \"model\"}` or nil."
  def default_model(%Scope{} = scope), do: default_model_for_workspace(Scope.workspace_id(scope))

  def default_model_for_workspace(nil), do: nil

  def default_model_for_workspace(workspace_id) do
    case Repo.get(Flux.Accounts.Workspace, workspace_id) do
      %{custom_config: %{"default_model" => %{} = default}} -> default
      _none -> nil
    end
  end

  defp validate_with_plugin(plugin_id, config) do
    case runtime().validate_credentials(plugin_id, config) do
      :ok -> :ok
      {:error, reason} when is_binary(reason) -> {:error, {:invalid_credentials, reason}}
      {:error, reason} -> {:error, {:invalid_credentials, inspect(reason)}}
    end
  end
end
