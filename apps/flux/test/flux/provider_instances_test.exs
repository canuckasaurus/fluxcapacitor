defmodule Flux.ProviderInstancesTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Providers

  # A clonable stand-in for openai_compatible: config-driven, no network.
  defmodule FakeRuntime do
    @compat %{
      id: "compat",
      name: "Compatible (fake)",
      version: "0.1.0",
      category: :model,
      description: "test provider",
      credential_schema: [%{key: "base_url"}, %{key: "api_key"}]
    }

    @keyless %{
      id: "keyless",
      name: "Keyless",
      version: "0.1.0",
      category: :model,
      description: "no credentials",
      credential_schema: []
    }

    @feed %{
      id: "feed",
      name: "Feed (fake)",
      version: "0.1.0",
      category: :datasource,
      description: "test datasource",
      credential_schema: [%{key: "url"}]
    }

    def list_model_providers, do: [@compat, @keyless]
    def list_datasource_plugins, do: [@feed]
    def validate_credentials(_plugin_id, _config), do: :ok

    def models(_plugin_id, config) do
      # Config-driven catalog, like openai_compatible's.
      name = config["model_name"] || "compat-default"
      {:ok, [%{name: name, label: name, type: :llm}]}
    end
  end

  setup do
    previous = Application.get_env(:flux, :plugin_runtime)
    Application.put_env(:flux, :plugin_runtime, FakeRuntime)
    on_exit(fn -> Application.put_env(:flux, :plugin_runtime, previous) end)

    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Instances WS"})
    scope = Accounts.scope_for(account)

    %{scope: scope, workspace: workspace}
  end

  test "clone, list, rename, delete an instance", %{scope: scope, workspace: workspace} do
    {:ok, instance_id, _credential} =
      Providers.create_provider_instance(scope, "compat", "Groq Prod", %{
        "base_url" => "https://groq.example.com/v1",
        "model_name" => "llama-groq"
      })

    assert instance_id == "compat@groq-prod"

    # Its credentials resolve under the instance id.
    assert {:ok, %{"base_url" => "https://groq.example.com/v1"}} =
             Providers.fetch_config(workspace.id, instance_id)

    # It lists as its own provider with its own (config-driven) catalog.
    assert [manifest] = Providers.instance_manifests(scope, :model)
    assert manifest.id == instance_id
    assert manifest.name == "Groq Prod"

    models = Providers.available_models(scope)
    assert Enum.any?(models, &(&1.plugin_id == instance_id and &1.model.name == "llama-groq"))

    # Ten coexist: a second instance of the same base is fine.
    {:ok, second_id, _credential} =
      Providers.create_provider_instance(scope, "compat", "Local vLLM", %{
        "base_url" => "http://vllm.internal/v1"
      })

    assert second_id == "compat@local-vllm"
    assert length(Providers.instance_manifests(scope, :model)) == 2

    # Renaming changes the label, never the id.
    {:ok, _workspace} = Providers.rename_provider_instance(scope, instance_id, "Groq (US East)")
    assert Providers.instance_label(workspace.id, instance_id) == "Groq (US East)"
    assert Enum.any?(Providers.instance_manifests(scope, :model), &(&1.id == instance_id))

    # Deleting removes credentials and the listing.
    :ok = Providers.delete_provider_instance(scope, instance_id)
    assert {:error, :not_configured} = Providers.fetch_config(workspace.id, instance_id)
    assert [%{id: ^second_id}] = Providers.instance_manifests(scope, :model)
  end

  test "colliding names are refused and never overwrite the original", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, instance_id, _credential} =
      Providers.create_provider_instance(scope, "compat", "Groq Prod", %{
        "base_url" => "https://original.example.com/v1"
      })

    # Every input that slugifies to the same id is a collision —
    # different case, underscores, extra spaces.
    for variant <- ["groq_prod", "GROQ PROD", "  groq   prod  ", "groq-prod"] do
      assert {:error, :name_taken} =
               Providers.create_provider_instance(scope, "compat", variant, %{
                 "base_url" => "https://usurper.example.com/v1"
               })
    end

    # The loser never touched the winner's credentials.
    assert {:ok, %{"base_url" => "https://original.example.com/v1"}} =
             Providers.fetch_config(workspace.id, instance_id)
  end

  test "base and instance stay entirely separate", %{scope: scope, workspace: workspace} do
    # Base credentials and instance credentials under the same plugin.
    {:ok, _credential} =
      Providers.upsert_credential(scope, "compat", %{"base_url" => "https://base.example.com"})

    {:ok, instance_id, _credential} =
      Providers.create_provider_instance(scope, "compat", "clone", %{
        "base_url" => "https://clone.example.com"
      })

    # Each resolves exactly its own config.
    assert {:ok, %{"base_url" => "https://base.example.com"}} =
             Providers.fetch_config(workspace.id, "compat")

    assert {:ok, %{"base_url" => "https://clone.example.com"}} =
             Providers.fetch_config(workspace.id, instance_id)

    # Pooling the base's key never bleeds into the instance's failover
    # candidates, and vice versa.
    [base_credential] =
      Enum.filter(Providers.list_credentials(scope), &(&1.plugin_id == "compat"))

    {:ok, _pooled} = Providers.set_credential_balanced(scope, base_credential.id, true)

    assert [%{"base_url" => "https://clone.example.com"}] =
             Providers.fetch_configs(workspace.id, instance_id)

    # Deleting the instance leaves the base untouched…
    :ok = Providers.delete_provider_instance(scope, instance_id)

    assert {:ok, %{"base_url" => "https://base.example.com"}} =
             Providers.fetch_config(workspace.id, "compat")

    # …and deleting the base's credential leaves other instances alone.
    {:ok, second_id, _credential} =
      Providers.create_provider_instance(scope, "compat", "survivor", %{
        "base_url" => "https://survivor.example.com"
      })

    {:ok, _deleted} = Providers.delete_credential(scope, base_credential.id)
    assert {:error, :not_configured} = Providers.fetch_config(workspace.id, "compat")

    assert {:ok, %{"base_url" => "https://survivor.example.com"}} =
             Providers.fetch_config(workspace.id, second_id)
  end

  test "workspaces never see each other's instances", %{scope: scope, workspace: workspace} do
    other_account = account_fixture()
    {:ok, {other_workspace, _}} = Accounts.create_workspace(other_account, %{name: "Other WS"})
    other_scope = Accounts.scope_for(Accounts.get_account!(other_account.id))

    # The same instance id can exist in both workspaces, fully disjoint.
    {:ok, instance_id, _credential} =
      Providers.create_provider_instance(scope, "compat", "shared-name", %{
        "base_url" => "https://mine.example.com"
      })

    {:ok, ^instance_id, _credential} =
      Providers.create_provider_instance(other_scope, "compat", "shared-name", %{
        "base_url" => "https://theirs.example.com"
      })

    assert {:ok, %{"base_url" => "https://mine.example.com"}} =
             Providers.fetch_config(workspace.id, instance_id)

    assert {:ok, %{"base_url" => "https://theirs.example.com"}} =
             Providers.fetch_config(other_workspace.id, instance_id)

    # Labels are per workspace too.
    {:ok, _ws} = Providers.rename_provider_instance(scope, instance_id, "Mine")
    assert Providers.instance_label(workspace.id, instance_id) == "Mine"
    assert Providers.instance_label(other_workspace.id, instance_id) == "shared-name"

    # Deleting mine leaves theirs standing.
    :ok = Providers.delete_provider_instance(scope, instance_id)
    assert Providers.instance_manifests(scope, :model) == []

    assert [%{id: ^instance_id}] = Providers.instance_manifests(other_scope, :model)
  end

  test "instance count is unbounded — well past ten", %{scope: scope} do
    for n <- 1..25 do
      {:ok, _id, _credential} =
        Providers.create_provider_instance(scope, "compat", "endpoint #{n}", %{
          "base_url" => "https://host-#{n}.example.com/v1"
        })
    end

    assert length(Providers.instance_manifests(scope, :model)) == 25
    assert length(Providers.available_models(scope)) >= 25
  end

  test "guards: duplicate names, blank names, keyless bases", %{scope: scope} do
    {:ok, _id, _credential} =
      Providers.create_provider_instance(scope, "compat", "prod", %{"base_url" => "https://x"})

    assert {:error, :name_taken} =
             Providers.create_provider_instance(scope, "compat", "prod", %{"base_url" => "y"})

    assert {:error, :invalid_name} =
             Providers.create_provider_instance(scope, "compat", "  !!!  ", %{"base_url" => "y"})

    assert {:error, :not_clonable} =
             Providers.create_provider_instance(scope, "keyless", "nope", %{})

    assert {:error, :not_an_instance} = Providers.delete_provider_instance(scope, "compat")
  end

  test "datasource instances list for the sync dropdown", %{scope: scope} do
    {:ok, instance_id, _credential} =
      Providers.create_provider_instance(scope, "feed", "News feed", %{"url" => "https://n"})

    assert [%{id: ^instance_id, category: :datasource}] =
             Providers.instance_manifests(scope, :datasource)

    assert Providers.instance_manifests(scope, :model) == []
  end
end
