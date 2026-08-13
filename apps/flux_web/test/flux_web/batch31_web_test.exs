defmodule FluxWeb.Batch31WebTest do
  use FluxWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.RAG

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch31 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "retrieval modes" do
    setup %{scope: scope} do
      {:ok, dataset} =
        RAG.create_dataset(scope, %{
          "name" => "Modes KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, _doc} =
        RAG.add_document(scope, dataset, %{
          name: "vacation.md",
          content: "Vacation policy: employees receive 25 paid days per year."
        })

      {:ok, _doc} =
        RAG.add_document(scope, dataset, %{
          name: "hoverboard.md",
          content: "Hoverboard maintenance requires a certified flux technician."
        })

      Oban.drain_queue(queue: :ingest)
      %{dataset: dataset}
    end

    test "keyword mode ranks by full-text match alone", %{scope: scope, dataset: dataset} do
      {:ok, dataset} = RAG.update_dataset(scope, dataset, %{"retrieval_mode" => "keyword"})

      {:ok, hits} = RAG.retrieve(scope, dataset.id, "hoverboard technician")
      assert hits != []
      assert hd(hits).content =~ "Hoverboard"
    end

    test "semantic mode still answers without keyword overlap", %{
      scope: scope,
      dataset: dataset
    } do
      {:ok, dataset} = RAG.update_dataset(scope, dataset, %{"retrieval_mode" => "semantic"})

      {:ok, hits} = RAG.retrieve(scope, dataset.id, "vacation days")
      assert hits != []
    end

    test "hybrid with a semantic weight still fuses both sources", %{
      scope: scope,
      dataset: dataset
    } do
      {:ok, dataset} =
        RAG.update_dataset(scope, dataset, %{
          "retrieval_mode" => "hybrid",
          "semantic_weight" => 0.9
        })

      {:ok, hits} = RAG.retrieve(scope, dataset.id, "hoverboard maintenance")
      assert hits != []
      assert hd(hits).content =~ "Hoverboard"
    end
  end

  describe "TOTP login flow" do
    test "password login detours through the code challenge", %{account: account} do
      account = set_password(account)
      {account, _uri} = Accounts.init_totp(Accounts.get_account!(account.id))
      code = NimbleTOTP.verification_code(account.totp_secret)
      {:ok, account, _recovery} = Accounts.confirm_totp(account, code)

      # Password alone parks the login and redirects to the challenge.
      conn =
        build_conn()
        |> post(~p"/accounts/log-in", %{
          "account" => %{"email" => account.email, "password" => valid_account_password()}
        })

      assert redirected_to(conn) == ~p"/accounts/totp"
      refute get_session(conn, :account_token)

      # The challenge page renders for the pending login.
      {:ok, _lv, html} = live(conn, ~p"/accounts/totp")
      assert html =~ "totp_form"

      # A wrong code bounces back.
      wrong = post(conn, ~p"/accounts/totp", %{"account" => %{"code" => "000000"}})
      assert redirected_to(wrong) == ~p"/accounts/totp"
      refute get_session(wrong, :account_token)

      # The right code completes the login.
      right =
        post(conn, ~p"/accounts/totp", %{
          "account" => %{"code" => NimbleTOTP.verification_code(account.totp_secret)}
        })

      assert get_session(right, :account_token)
    end

    test "accounts without 2FA log in directly", %{account: account} do
      account = set_password(account)

      conn =
        build_conn()
        |> post(~p"/accounts/log-in", %{
          "account" => %{"email" => account.email, "password" => valid_account_password()}
        })

      assert get_session(conn, :account_token)
    end

    test "the challenge page without a pending login goes back to log-in" do
      assert {:error, {:live_redirect, %{to: "/accounts/log-in"}}} =
               live(build_conn(), ~p"/accounts/totp")
    end
  end

  describe "site passcode" do
    setup %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Secret Site",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, app} = Chat.enable_site(scope, app)
      {:ok, app} = Chat.set_site_passcode(scope, app, "88mph")
      %{app: app}
    end

    test "visitors are challenged, then let through", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/site/#{app.site_token}")
      assert html =~ "site-passcode"
      assert html =~ "Secret Site"
      refute html =~ "chat-input"

      # Wrong passcode: back to the gate with an error flash.
      wrong = post(conn, ~p"/site/#{app.site_token}/passcode", %{"passcode" => "77mph"})
      assert redirected_to(wrong) == ~p"/site/#{app.site_token}"

      # Right passcode: the session opens and the site renders.
      right = post(conn, ~p"/site/#{app.site_token}/passcode", %{"passcode" => "88mph"})
      assert redirected_to(right) == ~p"/site/#{app.site_token}"

      {:ok, _lv, html} = live(right, ~p"/site/#{app.site_token}")
      refute html =~ "site-passcode"
      assert html =~ "Secret Site"
    end
  end

  describe "/v1/moderations" do
    test "guardrail patterns flag content", %{conn: conn, scope: scope} do
      {:ok, _workspace} = Flux.Guardrails.configure(scope, "plutonium", "block")
      {:ok, _token, raw} = Chat.create_workspace_token(scope)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/v1/moderations", %{"input" => ["buy plutonium here", "all quiet"]})

      assert %{"results" => [flagged, clean]} = json_response(conn, 200)
      assert flagged["flagged"] == true
      assert flagged["categories"]["pattern"] == true
      assert clean["flagged"] == false
    end

    test "empty input is a 400", %{conn: conn, scope: scope} do
      {:ok, _token, raw} = Chat.create_workspace_token(scope)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/v1/moderations", %{"input" => ""})

      assert json_response(conn, 400)
    end
  end

  describe "workspace IP allowlist" do
    test "requests from outside the list get 403 and an audit entry", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      {:ok, _token, raw} = Chat.create_workspace_token(scope)

      # Test conns come from 127.0.0.1 — allow only a far-away network.
      {:ok, _workspace} = Flux.IPAllowlist.configure(scope, "203.0.113.0/24")

      denied =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/v1/moderations", %{"input" => "hello"})

      assert %{"code" => "ip_forbidden"} = json_response(denied, 403)

      assert Flux.Repo.exists?(
               from(e in Flux.Audit.Entry,
                 where: e.workspace_id == ^workspace.id and e.action == "api.ip_rejected"
               ),
               skip_workspace_guard: true
             )

      # Allowing the loopback restores access.
      {:ok, _workspace} = Flux.IPAllowlist.configure(scope, "127.0.0.0/8")

      allowed =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/v1/moderations", %{"input" => "hello"})

      assert json_response(allowed, 200)
    end
  end

  describe "run comments UI" do
    test "posting a note on an expanded run", %{conn: conn, scope: scope, account: account} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Noted Flux"})

      run =
        Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
          workspace_id: Flux.Accounts.Scope.workspace_id(scope),
          workflow_id: workflow.id,
          status: :succeeded
        })

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/runs")

      lv |> element("tr#run-#{run.id}") |> render_click()

      html =
        lv
        |> element("#run-comment-form-#{run.id}")
        |> render_submit(%{"run_id" => run.id, "body" => "Great Scott, look at node 3"})

      assert html =~ "Great Scott, look at node 3"
      assert html =~ account.email
    end
  end
end
