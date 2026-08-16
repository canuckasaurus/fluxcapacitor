defmodule FluxWeb.Batch38WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch38 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B38 Web App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  describe "POST /v1/responses" do
    test "blocking request answers the Responses shape", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      body =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/v1/responses", %{
          "input" => "hello responses",
          "instructions" => "be brief"
        })
        |> json_response(200)

      assert body["object"] == "response"
      assert body["status"] == "completed"

      assert [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}] =
               body["output"]

      assert text =~ "hello responses"
      assert body["usage"]["total_tokens"] > 0
    end

    test "message-array input works; bad input is a 400", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, _token, raw} = Chat.create_api_token(scope, app)
      conn = put_req_header(conn, "authorization", "Bearer #{raw}")

      body =
        conn
        |> post(~p"/v1/responses", %{
          "input" => [
            %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "part one"}]}
          ]
        })
        |> json_response(200)

      assert [%{"content" => [%{"text" => text}]}] = body["output"]
      assert text =~ "part one"

      assert conn |> post(~p"/v1/responses", %{"input" => %{}}) |> json_response(400)
    end
  end

  describe "GET /v1/messages/:id/suggested" do
    test "answers suggestions for the app's own message", %{conn: conn, scope: scope} do
      app = echo_app(scope, %{"suggest_followups" => true})
      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "seed the thread")

      Enum.reduce_while(1..50, nil, fn _try, _acc ->
        case Flux.Repo.get!(Flux.Chat.Message, assistant.id, skip_workspace_guard: true) do
          %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
          done -> {:halt, done}
        end
      end)

      {:ok, _token, raw} = Chat.create_api_token(scope, app)
      conn = put_req_header(conn, "authorization", "Bearer #{raw}")

      body = conn |> get(~p"/v1/messages/#{assistant.id}/suggested") |> json_response(200)
      assert body["result"] == "success"
      assert is_list(body["data"])

      assert conn
             |> get(~p"/v1/messages/#{Ecto.UUID.generate()}/suggested")
             |> json_response(404)
    end
  end

  describe "dataset-scoped keys over the wire" do
    test "a ds- key opens its dataset and nothing else", %{conn: conn, scope: scope} do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Wire KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, _document} =
        Flux.RAG.add_document(scope, dataset, %{name: "doc.md", content: "keyed content"})

      {:ok, _token, raw} = Chat.create_dataset_token(scope, dataset.id)
      conn = put_req_header(conn, "authorization", "Bearer #{raw}")

      body = conn |> get(~p"/v1/datasets/#{dataset.id}/documents") |> json_response(200)
      assert is_list(body["data"])

      # The rest of the API answers 403 invalid_token_kind.
      assert conn |> get(~p"/v1/datasets") |> json_response(403)
      assert conn |> get(~p"/v1/usage") |> json_response(403)

      assert conn
             |> get(~p"/v1/datasets/#{Ecto.UUID.generate()}/documents")
             |> json_response(403)
    end
  end

  describe "login throttling" do
    test "a hammered email locks while others pass", %{conn: conn} do
      Application.put_env(:flux_web, :rate_limit_enabled, true)
      on_exit(fn -> Application.put_env(:flux_web, :rate_limit_enabled, false) end)

      email = "throttled-#{System.unique_integer([:positive])}@example.com"

      # Prime the per-email bucket past its limit (the router's per-IP
      # limiter would fire first if we POSTed sixteen times).
      email_hash =
        :sha256
        |> :crypto.hash(String.downcase(email))
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      for _try <- 1..15 do
        FluxWeb.RateLimit.hit("login:#{email_hash}", :timer.minutes(15), 15)
      end

      locked =
        build_conn()
        |> post(~p"/accounts/log-in", %{
          "account" => %{"email" => email, "password" => "wrong-password"}
        })

      assert Phoenix.Flash.get(locked.assigns.flash, :error) =~ "Too many sign-in attempts"

      # A different email is unaffected.
      other =
        conn
        |> post(~p"/accounts/log-in", %{
          "account" => %{
            "email" => "fresh-#{System.unique_integer([:positive])}@example.com",
            "password" => "wrong"
          }
        })

      assert Phoenix.Flash.get(other.assigns.flash, :error) == "Invalid email or password"
    end
  end

  describe "site localization and voice" do
    test "the public site speaks the browser's language", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      conn = put_req_header(conn, "accept-language", "de")
      {:ok, _lv, html} = live(conn, ~p"/site/#{app.site_token}")

      assert html =~ "Sag etwas, um das Gespräch zu beginnen."
      assert html =~ "mic-button"
    end
  end

  describe "index tags" do
    test "tag, chip, filter on the fluxes page", %{conn: conn, scope: scope, account: account} do
      {:ok, etl} = Flux.Workflows.create_workflow(scope, %{"name" => "ETL Flux"})
      {:ok, _plain} = Flux.Workflows.create_workflow(scope, %{"name" => "Plain Flux"})

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/fluxes")

      html =
        lv
        |> element("#tags-#{etl.id}")
        |> render_submit(%{"workflow-id" => etl.id, "tags" => "etl, prod"})

      assert html =~ "Tags saved."
      assert html =~ "tag-filter"

      html =
        lv |> element(~s(button[phx-click="filter_tag"][phx-value-tag="etl"])) |> render_click()

      assert html =~ "ETL Flux"
      refute html =~ "Plain Flux"
    end
  end

  describe "OIDC role mapping settings" do
    test "the card saves claim and value=role lines", %{
      conn: conn,
      scope: scope,
      account: account
    } do
      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/settings")

      lv
      |> element("#oidc-mapping-form")
      |> render_submit(%{
        "claim" => "groups",
        "mapping" => "builders=editor\nbad=owner\nops=admin"
      })

      scope = Accounts.scope_for(Accounts.get_account!(account.id))
      assert {"groups", mapping} = Accounts.oidc_role_mapping(scope)
      assert mapping == %{"builders" => "editor", "ops" => "admin"}
    end
  end

  describe "toolset import from URL" do
    test "an unreachable URL flashes the error", %{conn: conn, account: account} do
      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/tools")

      lv |> element(~s(button[phx-click="new"])) |> render_click()

      html =
        lv
        |> element("#toolset-url-form")
        |> render_submit(%{"url" => "http://127.0.0.1:9/openapi.json"})

      assert html =~ "not fetch" or render(lv) =~ "not fetch"
    end
  end

  describe "dataset key minting UI" do
    test "the knowledge page mints a ds- key shown once", %{
      conn: conn,
      scope: scope,
      account: account
    } do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Mint KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/knowledge?dataset=#{dataset.id}")

      html =
        case has_element?(lv, "#ds-token-card") do
          true ->
            lv |> element(~s(button[phx-click="mint_ds_token"])) |> render_click()

          false ->
            # Select the dataset first if deep-linking isn't wired.
            lv |> element("button", "Mint KB") |> render_click()
            lv |> element(~s(button[phx-click="mint_ds_token"])) |> render_click()
        end

      assert html =~ "ds-"
      assert html =~ "shown once"
    end
  end
end
