defmodule Flux.Hardening2Test do
  @moduledoc "Regression coverage for the batch-71 hardening exercise."
  use Flux.DataCase, async: false

  import Ecto.Query
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Guardrails
  alias Flux.SafeRegex

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Hardening2 WS"})
    scope = Accounts.scope_for(account)
    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  # A catastrophic-backtracking pattern applied to an adversarial input;
  # unbounded PCRE would run for seconds-to-minutes.
  @evil_pattern "(a+)+$"
  @evil_input String.duplicate("a", 60) <> "!"

  # Runs `fun` in a task and fails if it doesn't finish within `ms` — the
  # assertion is "this didn't hang a scheduler", not the return value.
  defp within(ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, ms) || Task.shutdown(task) do
      {:ok, result} -> result
      _timed_out -> flunk("operation did not complete within #{ms}ms (ReDoS?)")
    end
  end

  describe "SafeRegex backtracking budget" do
    test "a catastrophic pattern returns quickly instead of hanging" do
      {:ok, regex} = SafeRegex.compile(@evil_pattern)

      result = within(2_000, fn -> SafeRegex.match?(regex, @evil_input) end)
      assert result == false
    end

    test "ordinary matching and replacing still work" do
      {:ok, word} = SafeRegex.compile("foo")
      assert SafeRegex.match?(word, "a foo b")
      refute SafeRegex.match?(word, "a bar b")

      {:ok, digits} = SafeRegex.compile("\\d+", "")
      assert SafeRegex.replace(digits, "a1b22c", "#") == "a#b#c"
    end

    test "a non-binary subject is treated as no match, never a crash" do
      {:ok, regex} = SafeRegex.compile("x")
      refute SafeRegex.match?(regex, nil)
      refute SafeRegex.match?(regex, 123)
    end
  end

  describe "guardrail ReDoS" do
    test "a catastrophic deny pattern can't wedge check_input", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, _} = Guardrails.configure(scope, @evil_pattern, "block")

      result = within(2_000, fn -> Guardrails.check_input(workspace.id, @evil_input) end)
      # The pattern doesn't match the input, so the gate allows it — the
      # point is that it *returned* rather than pinning a scheduler.
      assert result == :ok
    end

    test "an ordinary deny pattern still blocks", %{scope: scope, workspace: workspace} do
      {:ok, _} = Guardrails.configure(scope, "secret", "block")
      assert Guardrails.check_input(workspace.id, "my secret plan") == {:error, :guardrail}
      assert Guardrails.check_input(workspace.id, "nothing here") == :ok
    end
  end

  describe "YAML expansion-bomb guards" do
    test "an anchor/alias bomb is rejected by the OpenAPI parser" do
      bomb = """
      openapi: "3.0.0"
      info:
        title: &a ["x","x","x","x","x","x","x","x","x"]
        version: *a
      paths:
        /x: { get: { responses: { "200": { description: ok } } } }
      """

      assert {:error, message} = Flux.Tools.OpenAPI.parse(bomb)
      assert message =~ "anchors/aliases"
    end

    test "a normal JSON spec still parses" do
      spec =
        ~s({"openapi":"3.0.0","info":{"title":"T","version":"1"},"paths":{"/x":{"get":{"responses":{"200":{"description":"ok"}}}}}})

      assert {:ok, %{operations: [_ | _]}} = Flux.Tools.OpenAPI.parse(spec)
    end

    test "an oversized spec is refused before parsing" do
      huge = "openapi: 3.0.0\n" <> String.duplicate("# pad\n", 400_000)
      assert {:error, message} = Flux.Tools.OpenAPI.parse(huge)
      assert message =~ "too large"
    end
  end

  describe "webhook signing secret stays out of Oban args" do
    test "dispatch references the endpoint, never embeds the secret", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, endpoint} =
        Flux.Webhooks.create_endpoint(scope, %{
          "url" => "https://example.com/hook",
          "events" => ["*"],
          "enabled" => true
        })

      :ok = Flux.Webhooks.dispatch(workspace.id, "test.event", %{"hello" => "world"})

      # (create_endpoint itself fires an audit webhook, so pick our event.)
      jobs =
        Flux.Repo.all(from j in Oban.Job, where: j.worker == "Flux.Workflows.AlertWorker")

      job = Enum.find(jobs, &(&1.args["payload"]["event"] == "test.event"))
      assert job

      # No job — not even the audit one — carries the secret in its args.
      refute Enum.any?(jobs, &Map.has_key?(&1.args, "secret"))
      assert job.args["endpoint_id"] == endpoint.id
      # The worker can still resolve the real secret at delivery time.
      assert Flux.Webhooks.endpoint_secret(endpoint.id) == endpoint.secret
    end
  end
end
