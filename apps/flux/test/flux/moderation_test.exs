defmodule Flux.ModerationTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Guardrails

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Mod WS"})
    scope = Accounts.scope_for(account)

    on_exit(fn -> Application.delete_env(:flux, :moderation_judge) end)

    %{scope: scope, workspace: workspace}
  end

  defp judge(verdict) do
    Application.put_env(:flux, :moderation_judge, fn _workspace_id, prompt ->
      send(self(), {:judged, prompt})
      verdict
    end)
  end

  test "blocking moderation refuses denied input and notifies", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, _} = Guardrails.configure_moderation(scope, "No competitor talk.", "block")
    judge("DENY: mentions a competitor")

    assert {:error, :guardrail} =
             Guardrails.check_input(workspace.id, "how does AcmeRival price this?", "test")

    assert_received {:judged, prompt}
    assert prompt =~ "No competitor talk."
    assert prompt =~ "AcmeRival"

    [notification | _] = Flux.Notifications.list(scope)
    assert notification.kind == "guardrail"
    assert notification.title =~ "moderation: mentions a competitor"
  end

  test "flag mode lets denied input through but still notifies", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, _} = Guardrails.configure_moderation(scope, "Be nice.", "flag")
    judge("DENY: rude")

    assert :ok = Guardrails.check_input(workspace.id, "grr", "test")
    assert [%{kind: "guardrail"}] = Flux.Notifications.list(scope)
  end

  test "ALLOW verdicts and judge failures both pass", %{scope: scope, workspace: workspace} do
    {:ok, _} = Guardrails.configure_moderation(scope, "Anything goes.", "block")

    judge("ALLOW")
    assert :ok = Guardrails.check_input(workspace.id, "hello", "test")

    # A judge that errors (returns garbage) must not block the product.
    judge("I cannot decide")
    assert :ok = Guardrails.check_input(workspace.id, "hello again", "test")
  end

  test "outputs are flag-only", %{scope: scope, workspace: workspace} do
    {:ok, _} = Guardrails.configure_moderation(scope, "No secrets.", "block")
    judge("DENY: leaked a secret")

    assert :ok = Guardrails.flag_output(workspace.id, "the password is hunter2", "test output")
    assert [%{kind: "guardrail", title: title}] = Flux.Notifications.list(scope)
    assert title =~ "moderation"
  end

  test "blank policy disables; regex guardrails still work alongside", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, _} = Guardrails.configure_moderation(scope, "Something", "block")
    {:ok, _} = Guardrails.configure_moderation(scope, "   ", "block")
    assert Guardrails.moderation_config(workspace.id) == nil

    # No judge configured, no moderation — plain regex still blocks.
    {:ok, _} = Guardrails.configure(scope, "forbidden", "block")
    assert {:error, :guardrail} = Guardrails.check_input(workspace.id, "forbidden fruit", "test")
  end
end
