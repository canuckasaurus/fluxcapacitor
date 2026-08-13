defmodule Flux.Batch31Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch31 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  describe "TOTP 2FA" do
    test "enroll, confirm, verify, and disable", %{account: account} do
      refute Accounts.totp_enabled?(account)

      {account, uri} = Accounts.init_totp(account)
      assert uri =~ "otpauth://totp/"
      assert uri =~ "FluxCapacitor"
      # Enrollment alone doesn't turn 2FA on.
      refute Accounts.totp_enabled?(account)

      assert {:error, :invalid_code} = Accounts.confirm_totp(account, "000000")

      code = NimbleTOTP.verification_code(account.totp_secret)
      assert {:ok, account, recovery_codes} = Accounts.confirm_totp(account, code)
      assert Accounts.totp_enabled?(account)
      assert length(recovery_codes) == 8

      # A current app code verifies.
      assert {:ok, _account} =
               Accounts.verify_totp(account, NimbleTOTP.verification_code(account.totp_secret))

      # A recovery code verifies exactly once.
      [recovery | _rest] = recovery_codes
      assert {:ok, _account} = Accounts.verify_totp(account, recovery)
      reloaded = Accounts.get_account!(account.id)
      assert length(reloaded.totp_recovery_codes) == 7
      assert {:error, :invalid_code} = Accounts.verify_totp(reloaded, recovery)

      disabled = Accounts.disable_totp(reloaded)
      refute Accounts.totp_enabled?(disabled)
      assert disabled.totp_secret == nil
      assert disabled.totp_recovery_codes == []
    end
  end

  describe "IP allowlist" do
    test "configure validates entries and allowed? matches CIDRs", %{
      scope: scope,
      workspace: workspace
    } do
      # No list: everyone is welcome.
      assert Flux.IPAllowlist.allowed?(workspace.id, {127, 0, 0, 1})

      assert {:error, {:invalid_cidr, "not-an-ip"}} =
               Flux.IPAllowlist.configure(scope, "10.0.0.0/8\nnot-an-ip")

      assert {:ok, _workspace} =
               Flux.IPAllowlist.configure(scope, "10.0.0.0/8\n192.168.1.42\n2001:db8::/32")

      assert Flux.IPAllowlist.list(workspace.id) == [
               "10.0.0.0/8",
               "192.168.1.42",
               "2001:db8::/32"
             ]

      assert Flux.IPAllowlist.allowed?(workspace.id, {10, 20, 30, 40})
      assert Flux.IPAllowlist.allowed?(workspace.id, {192, 168, 1, 42})
      refute Flux.IPAllowlist.allowed?(workspace.id, {192, 168, 1, 43})
      refute Flux.IPAllowlist.allowed?(workspace.id, {127, 0, 0, 1})
      assert Flux.IPAllowlist.allowed?(workspace.id, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      refute Flux.IPAllowlist.allowed?(workspace.id, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})

      # Blank clears the restriction.
      assert {:ok, _workspace} = Flux.IPAllowlist.configure(scope, "")
      assert Flux.IPAllowlist.allowed?(workspace.id, {127, 0, 0, 1})
    end
  end

  describe "site passcode" do
    test "set, check, and clear", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Gated App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, app} = Chat.set_site_passcode(scope, app, "flux88")
      assert app.site_passcode_hash != nil
      assert Chat.site_passcode_ok?(app, "flux88")
      assert Chat.site_passcode_ok?(app, "  flux88  ")
      refute Chat.site_passcode_ok?(app, "wrong")

      {:ok, cleared} = Chat.set_site_passcode(scope, app, "")
      assert cleared.site_passcode_hash == nil
      refute Chat.site_passcode_ok?(cleared, "flux88")
    end
  end

  describe "conversation auto-titles" do
    test "the derived title upgrades to the generated one", %{scope: scope} do
      previous = Application.get_env(:flux, :title_generator)
      Application.put_env(:flux, :title_generator, fn _content -> "Flux Capacitor Repairs" end)
      on_exit(fn -> Application.put_env(:flux, :title_generator, previous) end)

      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Title App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "hello there")

      title =
        Enum.reduce_while(1..50, nil, fn _try, _acc ->
          case Flux.Repo.get!(Flux.Chat.Conversation, conversation.id, skip_workspace_guard: true) do
            %{title: "Flux Capacitor Repairs"} = found -> {:halt, found.title}
            _pending -> Process.sleep(100) && {:cont, nil}
          end
        end)

      assert title == "Flux Capacitor Repairs"
    end

    test "a manual rename is never overwritten", %{scope: scope} do
      previous = Application.get_env(:flux, :title_generator)
      Application.put_env(:flux, :title_generator, fn _content -> "Generated" end)
      on_exit(fn -> Application.put_env(:flux, :title_generator, previous) end)

      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Title App 2",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      # A conversation that already has a title is not a first exchange —
      # the generator must not run over it.
      conversation = Chat.create_conversation(scope, app, %{title: "Keep me"})
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "hello")

      wait_for_completion(assistant.id)

      reloaded =
        Flux.Repo.get!(Flux.Chat.Conversation, conversation.id, skip_workspace_guard: true)

      assert reloaded.title == "Keep me"
    end
  end

  describe "per-key rate limits" do
    test "tokens store a validated limit", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Key App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, token, _raw} = Chat.create_api_token(scope, app, rate_limit_per_minute: 5)
      assert token.rate_limit_per_minute == 5

      {:ok, unlimited, _raw} = Chat.create_api_token(scope, app, rate_limit_per_minute: -3)
      assert unlimited.rate_limit_per_minute == nil

      {:ok, ws_token, _raw} = Chat.create_workspace_token(scope, rate_limit_per_minute: 100)
      assert ws_token.rate_limit_per_minute == 100
    end
  end

  describe "run comments" do
    test "add, list, and delete with authorization", %{scope: scope, workspace: workspace} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Commented Flux"})

      run =
        Flux.Repo.insert!(%Workflows.WorkflowRun{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :succeeded
        })

      assert {:error, :empty} = Workflows.add_run_comment(scope, run.id, "   ")

      {:ok, comment} = Workflows.add_run_comment(scope, run.id, "Looks flaky — rerun tomorrow")
      assert comment.body == "Looks flaky — rerun tomorrow"
      assert comment.account_id == scope.account.id

      assert [listed] = Workflows.list_run_comments(scope, run.id)
      assert listed.account.email == scope.account.email

      # A different member can't delete someone else's comment unless owner.
      other = account_fixture()

      {:ok, _membership} =
        %Flux.Accounts.Membership{}
        |> Flux.Accounts.Membership.changeset(%{
          workspace_id: workspace.id,
          account_id: other.id,
          role: :editor
        })
        |> Repo.insert()

      {:ok, _} = Accounts.switch_workspace(other, workspace.id)
      other_scope = Accounts.scope_for(other)

      assert {:error, :unauthorized} = Workflows.delete_run_comment(other_scope, comment.id)

      assert {:ok, _deleted} = Workflows.delete_run_comment(scope, comment.id)
      assert Workflows.list_run_comments(scope, run.id) == []
    end
  end

  describe "guardrails review" do
    test "flags pattern matches without blocking", %{scope: scope, workspace: workspace} do
      assert %{flagged: false} = Flux.Guardrails.review(workspace.id, "all quiet")

      {:ok, _workspace} = Flux.Guardrails.configure(scope, "plutonium", "block")

      assert %{flagged: true, pattern: "plutonium"} =
               Flux.Guardrails.review(workspace.id, "where do I buy PLUTONIUM?")

      assert %{flagged: false} = Flux.Guardrails.review(workspace.id, "still quiet")
    end
  end

  defp wait_for_completion(message_id) do
    Enum.reduce_while(1..50, nil, fn _try, _acc ->
      case Flux.Repo.get!(Flux.Chat.Message, message_id, skip_workspace_guard: true) do
        %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
        done -> {:halt, done}
      end
    end)
  end
end
