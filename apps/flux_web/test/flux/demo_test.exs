defmodule Flux.DemoTest do
  use FluxWeb.ConnCase, async: false

  test "the demo seeds once and everything runs on echo" do
    assert {:ok, seeded} = Flux.Demo.seed()
    assert {:error, :already_seeded} = Flux.Demo.seed()

    scope = Flux.Accounts.scope_for(seeded.account)

    # The knowledge base indexed inline and retrieves.
    {:ok, hits} = Flux.RAG.retrieve(scope, seeded.dataset.id, "how long do refunds take?")
    assert Enum.any?(hits, &(&1.content =~ "30 days"))

    # The triage flux routes refund questions down the refund branch.
    triage = Enum.find(seeded.fluxes, &(&1.name == "Support Triage"))
    {:ok, _run} = Flux.Workflows.start_run(scope, triage, %{"query" => "I want a refund"})
    assert_receive {:run_finished, finished}, 5_000
    assert finished.status == :succeeded
    assert finished.outputs["answer"] =~ "Refund question: I want a refund"

    # The chatflow app answers from the handbook.
    assistant = Enum.find(seeded.apps, &(&1.name == "Handbook Assistant"))
    conversation = Flux.Chat.create_conversation(scope, assistant)
    {:ok, _u, _a} = Flux.Chat.send_message(scope, assistant, conversation, "warranty length?")
    assert_receive {:done, reply}, 5_000
    assert reply.content =~ "two-year limited warranty"

    # The agent flux completes with the drive offered.
    agent = Enum.find(seeded.fluxes, &(&1.name == "Agent Scratchpad"))
    {:ok, _run} = Flux.Workflows.start_run(scope, agent, %{"query" => "plan a launch"})
    assert_receive {:run_finished, agent_run}, 5_000
    assert agent_run.status == :succeeded

    # The support app's public site is live.
    support = Enum.find(seeded.apps, &(&1.name == "Support Echo"))
    assert {:ok, _app} = Flux.Chat.get_app_by_site_token(support.site_token)
  end
end
