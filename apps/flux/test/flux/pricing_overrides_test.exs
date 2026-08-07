defmodule Flux.PricingOverridesTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Pricing

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Pricing WS"})
    %{scope: Accounts.scope_for(account), workspace: workspace}
  end

  test "workspace overrides price unknown models and beat the built-ins", %{
    scope: scope,
    workspace: workspace
  } do
    # Unknown model: no price anywhere.
    assert Pricing.estimate(workspace.id, "my-finetune-v2", 1_000_000, 0) == :unknown

    {:ok, _} =
      Pricing.configure_overrides(scope, """
      my-finetune 2.0 8.0
      gpt-4o 100.0 200.0
      """)

    # Prefix-matches the override.
    assert {:ok, cost} = Pricing.estimate(workspace.id, "my-finetune-v2", 1_000_000, 500_000)
    assert_in_delta cost, 2.0 + 4.0, 0.0001

    # Overrides beat the built-in table.
    assert {:ok, expensive} = Pricing.estimate(workspace.id, "gpt-4o", 1_000_000, 0)
    assert_in_delta expensive, 100.0, 0.0001

    # Other workspaces are untouched — the built-in gpt-4o price holds.
    assert {:ok, standard} = Pricing.estimate(nil, "gpt-4o", 1_000_000, 0)
    assert_in_delta standard, 2.5, 0.0001

    # cost_for flows the same overrides through run rollups.
    by_model = %{"my-finetune" => %{"input_tokens" => 1_000_000, "output_tokens" => 0}}
    assert Pricing.cost_for(workspace.id, by_model) == 2.0
    assert Pricing.cost_for(nil, by_model) == nil
  end

  test "bad lines refuse; blank clears", %{scope: scope, workspace: workspace} do
    assert {:error, {:invalid_line, _line}} =
             Pricing.configure_overrides(scope, "model-without-prices")

    {:ok, _} = Pricing.configure_overrides(scope, "m 1.0 2.0")
    assert Pricing.overrides(workspace.id) != %{}

    {:ok, _} = Pricing.configure_overrides(scope, "")
    assert Pricing.overrides(workspace.id) == %{}
  end
end
