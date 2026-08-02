defmodule Flux.LabelingTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Labeling
  alias Flux.Providers

  setup do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Label WS"})
    %{scope: Accounts.scope_for(account)}
  end

  test "unconfigured workspaces are told to add credentials first", %{scope: scope} do
    refute Labeling.configured?(scope)
    assert {:error, :not_configured} = Labeling.queue_item(scope, %{"question" => "q"})
  end

  test "queue_item pushes through the label_studio plugin credentials", %{scope: scope} do
    {:ok, _credential} =
      Providers.upsert_credential(scope, "label_studio", %{
        "base_url" => "http://labelstudio:8080",
        "api_token" => "ls-token"
      })

    assert Labeling.configured?(scope)

    assert {:ok, %{data: %{"task_count" => 1}}} =
             Labeling.queue_item(scope, %{"question" => "q", "answer" => "a"})
  end
end
