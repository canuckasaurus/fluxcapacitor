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
  Text-to-speech through the workspace default model's provider (the
  OpenAI-compat `/v1/audio/speech` endpoint). `opts` may carry `:model`
  and `:voice`. `{:error, :not_supported}` when no default is set or
  the provider has no speech endpoint.
  """
  def speak(workspace_id, text, opts \\ %{}) when is_binary(text) do
    case default_model_for_workspace(workspace_id) do
      %{"provider_plugin_id" => plugin_id} when is_binary(plugin_id) and plugin_id != "" ->
        credentials =
          case fetch_config(workspace_id, plugin_id) do
            {:ok, config} -> config
            {:error, :not_configured} -> %{}
          end

        runtime().invoke_speech(plugin_id, credentials, text, opts)

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

  ## Provider instances (clone a config-driven plugin under a new name)

  # An instance id is `base@slug` — the runtime resolves it to the base
  # plugin's module, but credentials, health, and app references all key
  # on the full instance id, so ten OpenAI-compatible endpoints coexist
  # as ten independent providers.

  @doc "The base plugin id of an instance id (`base@name` → `base`); others pass through."
  def base_plugin_id(plugin_id) when is_binary(plugin_id) do
    case String.split(plugin_id, "@", parts: 2) do
      [base, _instance] -> base
      [base] -> base
    end
  end

  @doc "Whether the id names a workspace-created provider instance."
  def instance_id?(plugin_id), do: is_binary(plugin_id) and String.contains?(plugin_id, "@")

  @doc """
  Clones a config-driven plugin as a named instance: `base@slug` gets
  its own credentials (validated against the base plugin) and shows up
  as its own provider everywhere. This is also how a "custom provider"
  is made — clone `openai_compatible` and point it at any endpoint.
  """
  def create_provider_instance(%Scope{} = scope, base_plugin_id, name, config)
      when is_map(config) do
    slug =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\-\s_]/, "")
      |> String.replace(~r/[\s_]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    instance_id = base_plugin_id <> "@" <> slug

    workspace_id = Scope.workspace_id(scope)

    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         true <- slug != "" || {:error, :invalid_name},
         true <- not instance_id?(base_plugin_id) || {:error, :nested_instance},
         true <-
           clonable?(base_plugin_id) || {:error, :not_clonable},
         :ok <- validate_with_plugin(instance_id, config),
         {:ok, encrypted} <- Crypto.encrypt(workspace_id, Jason.encode!(config)),
         # A plain insert, not the credential upsert: two concurrent
         # creates of the same name must NOT silently overwrite each
         # other — the unique index makes the loser an honest
         # :name_taken instead.
         {:ok, credential} <-
           %ProviderCredential{}
           |> ProviderCredential.changeset(%{
             workspace_id: workspace_id,
             plugin_id: instance_id,
             name: "default",
             is_default: true,
             encrypted_config: encrypted,
             validated_at: DateTime.utc_now(:second)
           })
           |> Repo.insert() do
      set_instance_label(scope, instance_id, String.trim(to_string(name)))

      Flux.Audit.record(scope, "provider.instance_create",
        resource_type: "provider_credential",
        resource_id: instance_id,
        metadata: %{"base" => base_plugin_id, "name" => name}
      )

      {:ok, instance_id, credential}
    else
      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :name) or
             Enum.any?(errors, fn {_field, {_message, meta}} ->
               meta[:constraint] == :unique
             end) do
          {:error, :name_taken}
        else
          {:error, :invalid_credentials}
        end

      other ->
        other
    end
  end

  # Any provider or datasource plugin that takes credentials can clone;
  # keyless plugins (echo) have nothing to instantiate.
  defp clonable?(base_plugin_id) do
    Enum.any?(
      runtime().list_model_providers() ++ runtime().list_datasource_plugins(),
      &(&1.id == base_plugin_id and &1.credential_schema != [])
    )
  end

  @doc "Renames an instance's display label (the id — and app references — never change)."
  def rename_provider_instance(%Scope{} = scope, instance_id, label) do
    label = label |> to_string() |> String.trim() |> String.slice(0, 80)

    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         true <- instance_id?(instance_id) || {:error, :not_an_instance},
         true <- label != "" || {:error, :invalid_name} do
      set_instance_label(scope, instance_id, label)
    end
  end

  @doc "Deletes an instance: its credentials and label go; apps pointing at it will error until repointed."
  def delete_provider_instance(%Scope{} = scope, instance_id) do
    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         true <- instance_id?(instance_id) || {:error, :not_an_instance} do
      {count, _} =
        ProviderCredential
        |> Repo.scoped(scope)
        |> where([c], c.plugin_id == ^instance_id)
        |> Repo.delete_all()

      set_instance_label(scope, instance_id, nil)

      Flux.Audit.record(scope, "provider.instance_delete",
        resource_type: "provider_credential",
        resource_id: instance_id,
        metadata: %{"credentials_removed" => count}
      )

      :ok
    end
  end

  @doc "The instance's display label (falls back to a humanized slug)."
  def instance_label(workspace_id, instance_id) do
    labels =
      case Repo.get(Flux.Accounts.Workspace, workspace_id) do
        %{custom_config: %{"provider_instance_labels" => %{} = labels}} -> labels
        _none -> %{}
      end

    labels[instance_id] ||
      instance_id |> String.split("@") |> List.last() |> String.replace("-", " ")
  end

  defp set_instance_label(scope, instance_id, label) do
    workspace = Repo.get(Flux.Accounts.Workspace, Scope.workspace_id(scope))
    labels = (workspace.custom_config || %{})["provider_instance_labels"] || %{}

    labels =
      if label, do: Map.put(labels, instance_id, label), else: Map.delete(labels, instance_id)

    custom_config =
      if labels == %{} do
        Map.delete(workspace.custom_config || %{}, "provider_instance_labels")
      else
        Map.put(workspace.custom_config || %{}, "provider_instance_labels", labels)
      end

    workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update()
  end

  @doc """
  Manifests for the workspace's provider instances: the base plugin's
  manifest re-badged with the instance id and label. `category` filters
  (`:model` for pickers, `:datasource` for sync dropdowns).
  """
  def instance_manifests(%Scope{} = scope, category \\ nil) do
    workspace_id = Scope.workspace_id(scope)

    instance_ids =
      ProviderCredential
      |> Repo.scoped(scope)
      |> where([c], like(c.plugin_id, "%@%"))
      |> select([c], c.plugin_id)
      |> distinct(true)
      |> Repo.all()
      |> Enum.sort()

    # Early out before touching the runtime — the common case, and it
    # keeps minimal test fakes (which only stub what they use) working.
    if instance_ids == [] do
      []
    else
      base_manifests =
        Map.new(runtime().list_model_providers() ++ runtime().list_datasource_plugins(), fn m ->
          {m.id, m}
        end)

      Enum.flat_map(
        instance_ids,
        &instance_manifest(&1, base_manifests, category, workspace_id)
      )
    end
  end

  defp instance_manifest(instance_id, base_manifests, category, workspace_id) do
    case base_manifests[base_plugin_id(instance_id)] do
      %{category: manifest_category} = manifest
      when category == nil or manifest_category == category ->
        [%{manifest | id: instance_id, name: instance_label(workspace_id, instance_id)}]

      _missing_or_filtered ->
        []
    end
  end

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
  tiebreak for rows predating the default flag) — unless any are flagged
  `balanced`, in which case calls rotate round-robin across the pool.
  """
  def fetch_config(workspace_id, plugin_id) do
    case fetch_configs(workspace_id, plugin_id) do
      [config | _rest] -> {:ok, config}
      [] -> {:error, :not_configured}
    end
  end

  @doc """
  Every decrypted candidate config for a plugin, failover order: with a
  load-balancing pool the rotation pick leads and the rest of the pool
  follows (so a failed call can move to the next key); without one it's
  just the default credential. `[]` when nothing is configured.
  """
  def fetch_configs(workspace_id, plugin_id) do
    credentials =
      from(c in ProviderCredential,
        where: c.workspace_id == ^workspace_id and c.plugin_id == ^plugin_id,
        order_by: [desc: c.is_default, asc: c.inserted_at, asc: c.id]
      )
      |> Repo.all()

    pool = Enum.filter(credentials, & &1.balanced)

    candidates =
      case pool do
        [] ->
          Enum.take(credentials, 1)

        pool ->
          # VM-wide monotonic counter as the rotor: successive calls land
          # on successive keys without any process owning the state.
          turn = rem(System.unique_integer([:positive, :monotonic]), length(pool))
          Enum.drop(pool, turn) ++ Enum.take(pool, turn)
      end

    for credential <- candidates,
        {:ok, json} <- [Crypto.decrypt(workspace_id, credential.encrypted_config)] do
      Jason.decode!(json)
    end
  end

  @doc "Flags a credential into (or out of) the load-balancing pool."
  def set_credential_balanced(%Scope{} = scope, credential_id, balanced?)
      when is_boolean(balanced?) do
    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         %ProviderCredential{} = credential <-
           Repo.one(Repo.scoped(where(ProviderCredential, id: ^credential_id), scope)) ||
             {:error, :not_found},
         {:ok, updated} <-
           credential |> Ecto.Changeset.change(balanced: balanced?) |> Repo.update() do
      Flux.Audit.record(scope, "provider.credential_balanced_set",
        resource_type: "provider_credential",
        resource_id: credential.id,
        metadata: %{"name" => credential.name, "balanced" => balanced?}
      )

      {:ok, updated}
    end
  end

  @doc """
  Runs `fun` (credentials → `{:ok, _} | {:error, reason}`) with the
  plugin's resolved credentials, moving to the next pooled key when a
  call fails with something that smells like a rate limit or provider
  outage. Providers with no stored credentials run once with `%{}`
  (keyless plugins like Echo).
  """
  def invoke_with_failover(workspace_id, plugin_id, fun) when is_function(fun, 1) do
    case fetch_configs(workspace_id, plugin_id) do
      [] -> fun.(%{})
      candidates -> try_candidates(candidates, fun)
    end
  end

  defp try_candidates([config], fun), do: fun.(config)

  defp try_candidates([config | rest], fun) do
    case fun.(config) do
      {:error, reason} = error ->
        if retryable_provider_error?(reason), do: try_candidates(rest, fun), else: error

      result ->
        result
    end
  end

  # The failures another key can plausibly fix: rate limits, quota
  # exhaustion, and provider-side outages. Bad requests stay bad.
  defp retryable_provider_error?(reason) do
    text = reason |> inspect() |> String.downcase()

    Enum.any?(
      [
        "429",
        "rate limit",
        "rate_limit",
        "quota",
        "overloaded",
        "timeout",
        "500",
        "502",
        "503",
        "529"
      ],
      &String.contains?(text, &1)
    )
  end

  @doc """
  Re-validates a saved credential against its provider on demand — keys
  expire between saves, and without this they only surface as cryptic
  run failures. Refreshes `validated_at` on success.
  """
  def validate_credential(%Scope{} = scope, credential_id) do
    workspace_id = Scope.workspace_id(scope)

    with :ok <- RBAC.authorize(scope, :plugin_model_config),
         %ProviderCredential{} = credential <-
           Repo.one(Repo.scoped(where(ProviderCredential, id: ^credential_id), scope)) ||
             {:error, :not_found},
         {:ok, json} <- Crypto.decrypt(workspace_id, credential.encrypted_config),
         :ok <- validate_with_plugin(credential.plugin_id, Jason.decode!(json)) do
      credential
      |> Ecto.Changeset.change(validated_at: DateTime.utc_now(:second))
      |> Repo.update()
    end
  end

  @doc """
  Models available to the workspace: every configured plugin's catalog, plus
  keyless plugins (empty credential schema, e.g. the Echo dev provider).
  """
  def available_models(%Scope{} = scope) do
    workspace_id = Scope.workspace_id(scope)
    configured = MapSet.new(list_credentials(scope), & &1.plugin_id)

    # Workspace-created instances list after the builtin providers, each
    # under its own label — ten OpenAI-compatible endpoints, ten entries.
    manifests = list_provider_plugins() ++ instance_manifests(scope, :model)

    for manifest <- manifests,
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
