defmodule FluxWeb.Batch24WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch24 Web WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Tools App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _token, raw} = Chat.create_api_token(scope, app)

    authed =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, authed: authed, scope: scope, workspace: workspace, app: app}
  end

  @weather_tool %{
    "type" => "function",
    "function" => %{
      "name" => "get_weather",
      "description" => "Look up weather",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}}
      }
    }
  }

  describe "OpenAI-compat tool calling" do
    test "a tool-inclined prompt answers tool_calls with finish_reason tool_calls", %{
      authed: authed
    } do
      response =
        authed
        |> post(
          ~p"/v1/chat/completions",
          Jason.encode!(%{
            "messages" => [%{"role" => "user", "content" => "please call the tool for Paris"}],
            "tools" => [@weather_tool]
          })
        )
        |> json_response(200)

      assert [%{"finish_reason" => "tool_calls", "message" => message}] = response["choices"]
      assert [call] = message["tool_calls"]
      assert call["type"] == "function"
      assert call["function"]["name"] == "get_weather"
      assert {:ok, %{"echo" => _prompt}} = Jason.decode(call["function"]["arguments"])
    end

    test "tool results round-trip to a final text answer", %{authed: authed} do
      response =
        authed
        |> post(
          ~p"/v1/chat/completions",
          Jason.encode!(%{
            "messages" => [
              %{"role" => "user", "content" => "what is the weather in Paris?"},
              %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "function" => %{
                      "name" => "get_weather",
                      "arguments" => ~s({"city": "Paris"})
                    }
                  }
                ]
              },
              %{
                "role" => "tool",
                "tool_call_id" => "call_1",
                "name" => "get_weather",
                "content" => "sunny, 21C"
              }
            ],
            "tools" => [@weather_tool]
          })
        )
        |> json_response(200)

      assert [%{"finish_reason" => "stop", "message" => %{"content" => content}}] =
               response["choices"]

      assert content =~ "what is the weather in Paris?"
    end

    test "streaming with tools emits a tool_calls delta before DONE", %{authed: authed} do
      conn =
        post(
          authed,
          ~p"/v1/chat/completions",
          Jason.encode!(%{
            "stream" => true,
            "messages" => [%{"role" => "user", "content" => "call the tool please"}],
            "tools" => [@weather_tool]
          })
        )

      body = response(conn, 200)
      assert body =~ ~s("tool_calls")
      assert body =~ ~s("finish_reason":"tool_calls")
      assert body =~ "data: [DONE]"
    end

    test "chatflow apps refuse tools honestly", %{conn: conn, scope: scope} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Flow"})

      {:ok, chatflow} =
        Chat.create_app(scope, %{
          "name" => "Flow App",
          "mode" => "advanced_chat",
          "workflow_id" => workflow.id
        })

      {:ok, _token, raw} = Chat.create_api_token(scope, chatflow)

      response =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/v1/chat/completions",
          Jason.encode!(%{
            "messages" => [%{"role" => "user", "content" => "hi"}],
            "tools" => [@weather_tool]
          })
        )
        |> json_response(400)

      assert response["error"]["message"] =~ "direct-model"
    end
  end

  describe "dataset content search" do
    test "finds segments by substring, case-insensitive", %{scope: scope} do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Search DS",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, _doc} =
        Flux.RAG.add_document(scope, dataset, %{
          name: "policy.md",
          content: "The Vacation allowance is 25 paid days."
        })

      {:ok, _doc} =
        Flux.RAG.add_document(scope, dataset, %{
          name: "shipping.md",
          content: "Shipping takes 3 to 5 business days."
        })

      Oban.drain_queue(queue: :ingest)

      hits = Flux.RAG.search_dataset(scope, dataset.id, "vacation ALLOWANCE")
      assert [%{document_name: "policy.md", segment: segment}] = hits
      assert segment.content =~ "25 paid days"

      assert Flux.RAG.search_dataset(scope, dataset.id, "   ") == []
      assert Flux.RAG.search_dataset(scope, dataset.id, "hoverboard") == []
    end
  end

  describe "knowledge webhook events" do
    test "document.indexed fires on ingestion for subscribed endpoints", %{scope: scope} do
      {:ok, _endpoint} =
        Flux.Webhooks.create_endpoint(scope, %{
          "url" => "https://hooks.example.com/knowledge",
          "events" => ["document.indexed", "document.failed", "dataset.synced"]
        })

      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Hook DS",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, document} =
        Flux.RAG.add_document(scope, dataset, %{name: "a.md", content: "hello hooks"})

      Oban.drain_queue(queue: :ingest)

      deliveries = Flux.Webhooks.list_deliveries(scope)

      assert delivery = Enum.find(deliveries, &(&1.event == "document.indexed"))
      assert delivery.payload["document_id"] == document.id
      assert delivery.payload["dataset_id"] == dataset.id
      assert delivery.payload["segments"] >= 1
    end
  end

  describe "/v1 conversation evals and A/B stats" do
    setup %{scope: scope, app: app} do
      Application.put_env(:flux, :eval_judge, fn _workspace_id, _messages ->
        {:ok, ~s({"score": 0.75, "reason": "fine"})}
      end)

      on_exit(fn -> Application.delete_env(:flux, :eval_judge) end)

      {:ok, eval} =
        Flux.ConversationEvals.create_conversation_eval(scope, app, %{
          "name" => "api eval",
          "expectation" => "replies to everything",
          "turns" => ["hello api"]
        })

      %{eval: eval}
    end

    test "list and run over the service API", %{authed: authed, eval: eval} do
      body = authed |> get(~p"/v1/conversation-evals") |> json_response(200)
      assert [%{"name" => "api eval", "turns" => 1, "last_score" => nil}] = body["data"]

      ran =
        authed
        |> post(~p"/v1/conversation-evals/#{eval.id}/run")
        |> json_response(200)

      assert ran["last_score"] == 0.75
      assert ran["last_reason"] == "fine"
      assert is_integer(ran["last_run_at"])
    end

    test "ab-stats answers per-variant counts", %{authed: authed, scope: scope, app: app} do
      {:ok, _app} =
        Chat.update_app(scope, app, %{
          "ab_provider_plugin_id" => "echo",
          "ab_model" => "echo-b",
          "ab_split" => 50
        })

      body = authed |> get(~p"/v1/ab-stats") |> json_response(200)
      assert body["split"] == 50
      assert body["challenger"] == "echo/echo-b"
      assert %{"a" => %{"replies" => 0}, "b" => %{"replies" => 0}} = body["data"]
    end

    test "a foreign eval id 404s", %{conn: conn, authed: authed, scope: scope} do
      {:ok, other_app} =
        Chat.create_app(scope, %{
          "name" => "Other",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, foreign} =
        Flux.ConversationEvals.create_conversation_eval(scope, other_app, %{
          "name" => "foreign",
          "expectation" => "n/a",
          "turns" => ["x"]
        })

      response =
        authed
        |> post(~p"/v1/conversation-evals/#{foreign.id}/run")
        |> json_response(404)

      assert response["code"] == "not_found"
      _ = conn
    end
  end
end
