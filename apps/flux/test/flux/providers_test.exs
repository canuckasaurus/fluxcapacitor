defmodule Flux.ProvidersTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Providers

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Prov WS"})
    %{scope: Accounts.scope_for(account), workspace: workspace}
  end

  test "upsert validates with the plugin and stores ciphertext", %{
    scope: scope,
    workspace: workspace
  } do
    assert {:error, {:invalid_credentials, _}} =
             Providers.upsert_credential(scope, "openai", %{"api_key" => "wrong"})

    assert {:ok, credential} =
             Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})

    assert credential.validated_at
    refute credential.encrypted_config =~ "sk-valid"

    assert {:ok, %{"api_key" => "sk-valid"}} = Providers.fetch_config(workspace.id, "openai")
  end

  test "upsert replaces existing credentials", %{scope: scope, workspace: workspace} do
    {:ok, _} = Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})
    {:ok, _} = Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})

    assert length(Providers.list_credentials(scope)) == 1
    assert {:ok, %{"api_key" => "sk-valid"}} = Providers.fetch_config(workspace.id, "openai")
  end

  test "configuring openai unlocks its models", %{scope: scope} do
    refute Enum.any?(Providers.available_models(scope), &(&1.plugin_id == "openai"))

    {:ok, _} = Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})

    assert Enum.any?(
             Providers.available_models(scope),
             &(&1.plugin_id == "openai" and &1.model.name == "gpt-4o")
           )
  end

  test "credential management requires plugin_model_config", %{scope: scope} do
    member = account_fixture()
    workspace_id = Flux.Accounts.Scope.workspace_id(scope)

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace_id,
        account_id: member.id,
        role: :normal
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, workspace_id)
    member_scope = Accounts.scope_for(member)

    assert {:error, :unauthorized} =
             Providers.upsert_credential(member_scope, "openai", %{"api_key" => "sk-valid"})
  end

  test "delete removes credentials", %{scope: scope, workspace: workspace} do
    {:ok, credential} = Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})
    assert {:ok, _} = Providers.delete_credential(scope, credential.id)
    assert {:error, :not_configured} = Providers.fetch_config(workspace.id, "openai")
  end
end
