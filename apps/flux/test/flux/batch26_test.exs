defmodule Flux.Batch26Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch26 WS"})
    scope = Accounts.scope_for(account)

    %{scope: scope, workspace: workspace, account: account}
  end

  describe "cost spike alerts" do
    defp seed_message!(workspace_id, conversation, days_ago, tokens) do
      Flux.Repo.insert!(%Flux.Chat.Message{
        workspace_id: workspace_id,
        conversation_id: conversation.id,
        role: :assistant,
        status: :completed,
        content: "seed",
        usage: %{"input_tokens" => 0, "output_tokens" => tokens},
        inserted_at:
          DateTime.utc_now(:second) |> DateTime.add(-days_ago, :day) |> DateTime.truncate(:second)
      })
    end

    test "a yesterday spike over 2x the trailing average notifies", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Spike App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app)

      # A quiet prior week, then a 150k-token yesterday.
      for days_ago <- 2..7, do: seed_message!(workspace.id, conversation, days_ago, 1_000)
      seed_message!(workspace.id, conversation, 1, 150_000)

      now = DateTime.utc_now(:second) |> Map.merge(%{hour: 8, minute: 10})
      assert :ok = Flux.Usage.check_cost_spikes(now)

      titles = Enum.map(Flux.Notifications.list(scope), & &1.title)
      assert Enum.any?(titles, &(&1 =~ "Token spend spiked"))
    end

    test "quiet workspaces stay quiet", %{scope: scope, workspace: workspace} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Quiet App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app)
      for days_ago <- 1..7, do: seed_message!(workspace.id, conversation, days_ago, 5_000)

      now = DateTime.utc_now(:second) |> Map.merge(%{hour: 8, minute: 10})
      assert :ok = Flux.Usage.check_cost_spikes(now)

      titles = Enum.map(Flux.Notifications.list(scope), & &1.title)
      refute Enum.any?(titles, &(&1 =~ "Token spend spiked"))
    end
  end

  describe "input presets" do
    test "save, replace, and delete presets", %{scope: scope} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Preset Flux"})

      assert {:error, :blank_name} =
               Flux.Workflows.save_input_preset(scope, workflow, "  ", %{"query" => "x"})

      {:ok, workflow} =
        Flux.Workflows.save_input_preset(scope, workflow, "smoke", %{"query" => "hello"})

      assert workflow.input_presets == %{"smoke" => %{"query" => "hello"}}

      {:ok, workflow} =
        Flux.Workflows.save_input_preset(scope, workflow, "smoke", %{"query" => "replaced"})

      assert workflow.input_presets["smoke"]["query"] == "replaced"

      {:ok, workflow} = Flux.Workflows.delete_input_preset(scope, workflow, "smoke")
      assert workflow.input_presets == %{}
    end
  end

  describe "provider speech" do
    test "speak routes through the default provider", %{scope: scope, workspace: workspace} do
      assert {:error, :not_supported} = Flux.Providers.speak(workspace.id, "hello")

      {:ok, _} = Flux.Providers.set_default_model(scope, "echo", "echo-1")

      assert {:ok, %{audio: "FAKE-MP3:" <> _rest, content_type: "audio/mpeg"}} =
               Flux.Providers.speak(workspace.id, "hello there")
    end
  end

  describe "site visitor feedback" do
    test "the unauthenticated site scope can rate replies", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Site App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "visitor-9"})
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "rate me")
      assert_receive {:done, reply}, 5_000

      site_scope = Chat.site_scope(app)
      assert {:ok, liked} = Chat.set_feedback(site_scope, reply.id, :like)
      assert liked.feedback == :like

      assert {:ok, cleared} = Chat.set_feedback(site_scope, reply.id, nil)
      assert cleared.feedback == nil
    end
  end
end
