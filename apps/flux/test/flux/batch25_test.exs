defmodule Flux.Batch25Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch25 WS"})
    scope = Accounts.scope_for(account)

    %{scope: scope, workspace: workspace, account: account}
  end

  describe "embedding cache" do
    test "identical texts embed once; the second pass is all hits", %{workspace: workspace} do
      texts = ["the flux capacitor #{System.unique_integer()}", "88 miles per hour"]

      before_stats = Flux.EmbeddingCache.stats()

      {:ok, first} = Flux.Providers.embed_texts(workspace.id, "echo", "echo-embed", texts)
      {:ok, second} = Flux.Providers.embed_texts(workspace.id, "echo", "echo-embed", texts)

      assert first == second

      after_stats = Flux.EmbeddingCache.stats()
      assert after_stats.hits >= before_stats.hits + 2

      # Partial hit: one cached text plus one new one still lines up.
      {:ok, [cached_vector, _fresh]} =
        Flux.Providers.embed_texts(workspace.id, "echo", "echo-embed", [
          hd(texts),
          "brand new text #{System.unique_integer()}"
        ])

      assert cached_vector == hd(first)
    end
  end

  describe "conversation trash" do
    setup %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Trash App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      %{app: app}
    end

    test "delete soft-deletes, restore brings it back", %{scope: scope, app: app} do
      conversation = Chat.create_conversation(scope, app, %{title: "keep me"})

      assert {:ok, trashed} = Chat.delete_conversation(scope, conversation.id)
      assert trashed.deleted_at

      refute Enum.any?(Chat.console_conversations(scope, app.id), &(&1.id == conversation.id))
      refute Enum.any?(Chat.list_conversations(scope, app.id), &(&1.id == conversation.id))

      assert [%{id: trashed_id}] = Chat.list_trashed_conversations(scope, app.id)
      assert trashed_id == conversation.id

      assert {:ok, restored} = Chat.restore_conversation(scope, conversation.id)
      assert restored.deleted_at == nil
      assert Enum.any?(Chat.console_conversations(scope, app.id), &(&1.id == conversation.id))
      assert Chat.list_trashed_conversations(scope, app.id) == []
    end
  end

  describe "visitor stats" do
    test "rolls up conversations, messages, and feedback per visitor", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Visitors App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "visitor-1"})
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "hi there")
      assert_receive {:done, reply}, 5_000
      {:ok, _} = Chat.set_feedback(scope, reply.id, :like)

      _quiet = Chat.create_conversation(scope, app, %{end_user_ref: "visitor-2"})

      stats = Chat.visitor_stats(scope, app.id)
      busy = Enum.find(stats, &(&1.ref == "visitor-1"))

      assert busy.conversations == 1
      assert busy.messages == 2
      assert busy.likes == 1
      assert busy.tokens > 0
      assert Enum.any?(stats, &(&1.ref == "visitor-2"))
    end
  end

  describe "publish notes" do
    test "notes stick to versions; blanks stay nil", %{scope: scope} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Notes Flux"})

      {:ok, noted} = Flux.Workflows.publish(scope, workflow, "  first cut  ")
      assert noted.note == "first cut"

      {:ok, unnoted} = Flux.Workflows.publish(scope, workflow, "   ")
      assert unnoted.note == nil
    end
  end

  describe "prompt snippet versioning" do
    test "edits archive, history lists, restore round-trips", %{scope: scope} do
      {:ok, _v1} = Flux.Prompts.upsert(scope, "greeting", "Hello there.")
      {:ok, snippet} = Flux.Prompts.upsert(scope, "greeting", "General Kenobi.")

      assert [%{version: 1, content: "Hello there."}] = Flux.Prompts.versions(scope, snippet.id)

      # Saving identical content archives nothing.
      {:ok, _same} = Flux.Prompts.upsert(scope, "greeting", "General Kenobi.")
      assert length(Flux.Prompts.versions(scope, snippet.id)) == 1

      {:ok, restored} = Flux.Prompts.restore_version(scope, snippet.id, 1)
      assert restored.content == "Hello there."

      # The restore archived the replaced content as v2.
      versions = Flux.Prompts.versions(scope, snippet.id)
      assert [%{version: 2, content: "General Kenobi."}, %{version: 1}] = versions
    end
  end
end
