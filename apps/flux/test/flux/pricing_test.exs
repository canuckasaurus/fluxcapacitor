defmodule Flux.PricingTest do
  use ExUnit.Case, async: false

  alias Flux.Pricing

  test "prices known models per million tokens" do
    assert {:ok, cost} = Pricing.estimate("claude-opus-5", 1_000_000, 1_000_000)
    assert_in_delta cost, 5.0 + 25.0, 1.0e-9
  end

  test "dated snapshots resolve by longest prefix" do
    # "claude-opus-4-8-20260101" matches both "claude-opus-4" (15/75) and
    # "claude-opus-4-8" (5/25); the longer, cheaper row must win.
    assert {:ok, cost} = Pricing.estimate("claude-opus-4-8-20260101", 1_000_000, 0)
    assert_in_delta cost, 5.0, 1.0e-9
  end

  test "unknown models are :unknown, not zero" do
    assert Pricing.estimate("my-local-llama", 100, 100) == :unknown
  end

  test "cost_for sums known models and skips unknown ones" do
    by_model = %{
      "gpt-4o" => %{"input_tokens" => 1_000_000, "output_tokens" => 0},
      "mystery-model" => %{"input_tokens" => 999, "output_tokens" => 999}
    }

    assert_in_delta Pricing.cost_for(by_model), 2.5, 1.0e-9
  end

  test "cost_for is nil when nothing is priced" do
    assert Pricing.cost_for(%{"mystery-model" => %{"input_tokens" => 5}}) == nil
    assert Pricing.cost_for(%{}) == nil
  end

  test "config overrides extend the table" do
    Application.put_env(:flux, :model_pricing, %{"my-finetune" => {2.0, 8.0}})
    on_exit(fn -> Application.delete_env(:flux, :model_pricing) end)

    assert {:ok, cost} = Pricing.estimate("my-finetune-v3", 500_000, 500_000)
    assert_in_delta cost, 1.0 + 4.0, 1.0e-9
  end
end
