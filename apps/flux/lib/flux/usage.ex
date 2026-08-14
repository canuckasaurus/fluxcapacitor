defmodule Flux.Usage do
  @moduledoc """
  Workspace-wide usage rollups for the console dashboard: tokens and
  replies across every app, run counts by status, storage, and knowledge
  size. Per-app detail lives on each app's monitor page.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Chat.{Conversation, Message}
  alias Flux.Repo
  alias Flux.Workflows.WorkflowRun

  def workspace_summary(%Scope{} = scope, days \\ 14) do
    since = DateTime.add(DateTime.utc_now(:second), -days, :day)

    %{
      days: days,
      tokens: token_totals(scope, since),
      daily: daily_tokens(scope, since),
      runs: run_counts(scope, since),
      run_tokens: run_token_totals(scope, since),
      top_apps: top_apps(scope, since),
      storage_bytes: storage_bytes(scope),
      knowledge: knowledge_counts(scope)
    }
  end

  @doc """
  The quality loop at a glance for the dashboard: gate coverage, the
  most recent eval scores, and the labeling queue with its agreement.
  """
  def quality_summary(%Scope{} = scope) do
    projects = Flux.Labeling.list_projects(scope)

    unlabeled =
      Enum.sum(for project <- projects, do: Flux.Labeling.counts(scope, project.id).unlabeled)

    agreements =
      for project <- projects,
          project.required_labels > 1,
          stats = Flux.Labeling.agreement_stats(scope, project.id),
          do: stats.avg_agreement

    sets =
      Flux.Evals.EvalSet
      |> Repo.scoped(scope)
      |> Repo.all()

    recent_evals =
      Flux.Evals.EvalRun
      |> Repo.scoped(scope)
      |> where([r], r.status == :completed)
      |> order_by([r], desc: r.inserted_at)
      |> limit(5)
      |> Repo.all()
      |> Enum.map(fn eval_run ->
        set = Enum.find(sets, &(&1.id == eval_run.eval_set_id))

        %{
          set_name: (set && set.name) || "deleted set",
          target: eval_run.target,
          avg_score: eval_run.avg_score,
          passed: eval_run.passed,
          failed: eval_run.failed
        }
      end)

    %{
      gated_sets: Enum.count(sets, & &1.gate),
      scheduled_sets: Enum.count(sets, & &1.schedule),
      recent_evals: recent_evals,
      labeling_projects: length(projects),
      unlabeled_tasks: unlabeled,
      avg_agreement:
        case agreements do
          [] -> nil
          agreements -> Enum.sum(agreements) / length(agreements)
        end
    }
  end

  @doc """
  Monday-morning digests (minute-tick sweep, 08:00 UTC): every workspace
  with run activity in the past week gets one `digest` notification —
  runs, failures, tokens, and estimated cost — routable to webhooks like
  any other kind. A per-week marker in custom_config stops repeats.
  """
  def send_weekly_digests(now \\ DateTime.utc_now(:second)) do
    if now.hour == 8 and now.minute == 0 do
      monday? = Date.day_of_week(DateTime.to_date(now)) == 1
      {year, week_number} = :calendar.iso_week_number(Date.to_erl(DateTime.to_date(now)))
      week = "#{year}-#{week_number}"
      day = Date.to_iso8601(DateTime.to_date(now))

      # digest_frequency: "weekly" (default, Mondays), "daily", or "off".
      for workspace <- Repo.all(Flux.Accounts.Workspace),
          frequency = (workspace.custom_config || %{})["digest_frequency"] || "weekly",
          frequency != "off",
          frequency == "daily" or monday?,
          period = (frequency == "daily" && day) || week,
          since = DateTime.add(now, (frequency == "daily" && -1) || -7, :day),
          (workspace.custom_config || %{})["digest_sent"] != period do
        runs =
          Flux.Workflows.WorkflowRun
          |> where([r], r.workspace_id == ^workspace.id and r.inserted_at >= ^since)
          |> select([r], %{status: r.status, usage: r.usage})
          |> Repo.all(skip_workspace_guard: true)

        if runs != [] do
          failed = Enum.count(runs, &(&1.status == :failed))

          tokens =
            Enum.sum(
              for run <- runs,
                  do: (run.usage["input_tokens"] || 0) + (run.usage["output_tokens"] || 0)
            )

          cost = Enum.sum(for run <- runs, do: run.usage["estimated_cost_usd"] || 0.0)

          cost_text =
            (cost > 0 && " · ~$#{:erlang.float_to_binary(cost * 1.0, decimals: 4)}") || ""

          Flux.Notifications.notify(
            workspace.id,
            "digest",
            "#{(frequency == "daily" && "Daily") || "Weekly"} digest: " <>
              "#{length(runs)} runs (#{failed} failed) · #{tokens} tokens#{cost_text}",
            "/console/runs"
          )

          workspace
          |> Ecto.Changeset.change(
            custom_config: Map.put(workspace.custom_config || %{}, "digest_sent", period)
          )
          |> Repo.update()
        end
      end
    end

    :ok
  end

  @doc """
  Monthly cost reports (minute-tick sweep, 1st of the month 08:00 UTC):
  every workspace with run activity last month gets one `cost_report`
  notification — tokens, estimated USD, top fluxes — which reaches
  opted-in members by email through the notification fan-out. A
  per-month marker in custom_config stops repeats.
  """
  def send_monthly_cost_reports(now \\ DateTime.utc_now(:second)) do
    today = DateTime.to_date(now)

    if today.day == 1 and now.hour == 8 and now.minute == 0 do
      last_month_start = today |> Date.add(-1) |> Date.beginning_of_month()
      month = Calendar.strftime(last_month_start, "%Y-%m")
      since = DateTime.new!(last_month_start, ~T[00:00:00])
      until = DateTime.new!(Date.beginning_of_month(today), ~T[00:00:00])

      for workspace <- Repo.all(Flux.Accounts.Workspace),
          (workspace.custom_config || %{})["cost_report_sent"] != month do
        runs =
          Flux.Workflows.WorkflowRun
          |> where(
            [r],
            r.workspace_id == ^workspace.id and r.inserted_at >= ^since and
              r.inserted_at < ^until
          )
          |> select([r], %{workflow_id: r.workflow_id, usage: r.usage})
          |> Repo.all(skip_workspace_guard: true)

        if runs != [] do
          tokens =
            Enum.sum(
              for run <- runs,
                  do: (run.usage["input_tokens"] || 0) + (run.usage["output_tokens"] || 0)
            )

          cost = Enum.sum(for run <- runs, do: run.usage["estimated_cost_usd"] || 0.0)

          top =
            runs
            |> Enum.group_by(& &1.workflow_id)
            |> Enum.map(fn {workflow_id, group} -> {workflow_id, length(group)} end)
            |> Enum.sort_by(fn {_id, count} -> -count end)
            |> Enum.take(3)
            |> Enum.map_join(", ", fn {workflow_id, count} ->
              name =
                (workflow_id &&
                   case Repo.get(Flux.Workflows.Workflow, workflow_id, skip_workspace_guard: true) do
                     %{name: name} -> name
                     nil -> "deleted flux"
                   end) || "ad-hoc"

              "#{name} (#{count})"
            end)

          cost_text =
            (cost > 0 && " · ~$#{:erlang.float_to_binary(cost * 1.0, decimals: 2)}") || ""

          Flux.Notifications.notify(
            workspace.id,
            "cost_report",
            "#{month} cost report: #{length(runs)} runs · #{tokens} tokens#{cost_text} · top: #{top}",
            "/console/runs"
          )

          workspace
          |> Ecto.Changeset.change(
            custom_config: Map.put(workspace.custom_config || %{}, "cost_report_sent", month)
          )
          |> Repo.update()
        end
      end
    end

    :ok
  end

  @spike_floor 100_000

  @doc """
  Daily 08:10 UTC tick: a workspace whose yesterday token spend more
  than doubled its trailing 7-day average (and cleared a #{@spike_floor}
  floor) gets a `budget_warning` notification — budgets catch slow
  burn, this catches the sudden spike.
  """
  def check_cost_spikes(now \\ DateTime.utc_now(:second)) do
    if now.hour == 8 and now.minute == 10 do
      today = DateTime.to_date(now)
      yesterday = Date.add(today, -1)
      window_start = today |> Date.add(-8) |> DateTime.new!(~T[00:00:00])
      today_start = DateTime.new!(today, ~T[00:00:00])

      rows =
        daily_tokens(Flux.Workflows.WorkflowRun, window_start, today_start) ++
          daily_tokens(Flux.Chat.Message, window_start, today_start)

      rows
      |> Enum.group_by(fn {workspace_id, _date, _tokens} -> workspace_id end)
      |> Enum.each(fn {workspace_id, entries} ->
        by_date =
          Enum.reduce(entries, %{}, fn {_ws, date, tokens}, acc ->
            Map.update(acc, date, tokens, &(&1 + tokens))
          end)

        spent_yesterday = Map.get(by_date, yesterday, 0)
        prior = by_date |> Map.delete(yesterday) |> Map.values() |> Enum.sum()
        daily_average = max(div(prior, 7), 1)

        if spent_yesterday >= @spike_floor and spent_yesterday > 2 * daily_average do
          Flux.Notifications.notify(
            workspace_id,
            "budget_warning",
            "Token spend spiked: #{spent_yesterday} tokens yesterday vs ~#{daily_average}/day " <>
              "over the prior week.",
            "/console"
          )
        end
      end)
    end

    :ok
  end

  defp daily_tokens(schema, window_start, today_start) do
    schema
    |> where([x], x.inserted_at >= ^window_start and x.inserted_at < ^today_start)
    |> where([x], not is_nil(x.usage))
    |> group_by([x], [x.workspace_id, fragment("date(?)", x.inserted_at)])
    |> select(
      [x],
      {x.workspace_id, fragment("date(?)", x.inserted_at),
       fragment(
         "(coalesce(sum(coalesce((? ->> 'input_tokens')::bigint, 0) + coalesce((? ->> 'output_tokens')::bigint, 0)), 0))::bigint",
         x.usage,
         x.usage
       )}
    )
    |> Repo.all(skip_workspace_guard: true)
  end

  @doc "This calendar month's run tokens for one flux (per-flux budgets)."
  def month_tokens_for_workflow(workflow_id) do
    month_start =
      Date.utc_today()
      |> Date.beginning_of_month()
      |> DateTime.new!(~T[00:00:00])

    Flux.Workflows.WorkflowRun
    |> where([r], r.workflow_id == ^workflow_id and r.inserted_at >= ^month_start)
    |> select([r], r.usage)
    |> Repo.all(skip_workspace_guard: true)
    |> Enum.reduce(0, fn usage, acc ->
      acc + (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
    end)
  end

  @doc """
  Tokens spent this calendar month across workflow runs and chat replies
  — the number the monthly budget gate compares against. Worker-safe (no
  scope).
  """
  def month_tokens(workspace_id) do
    month_start =
      Date.utc_today()
      |> Date.beginning_of_month()
      |> DateTime.new!(~T[00:00:00])

    run_tokens =
      Flux.Workflows.WorkflowRun
      |> where([r], r.workspace_id == ^workspace_id and r.inserted_at >= ^month_start)
      |> select([r], r.usage)
      |> Repo.all(skip_workspace_guard: true)
      |> Enum.reduce(0, fn usage, acc ->
        acc + (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
      end)

    chat_tokens =
      Flux.Chat.Message
      |> where([m], m.workspace_id == ^workspace_id and m.inserted_at >= ^month_start)
      |> where([m], not is_nil(m.usage))
      |> select([m], m.usage)
      |> Repo.all(skip_workspace_guard: true)
      |> Enum.reduce(0, fn usage, acc ->
        acc + (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
      end)

    run_tokens + chat_tokens
  end

  @doc """
  Per-flux run/token/cost totals over the window, most expensive first —
  the dedicated cost surface (runs page card + CSV export).
  """
  def flux_costs(%Scope{} = scope, days \\ 30) do
    since = DateTime.add(DateTime.utc_now(:second), -days, :day)

    runs =
      Flux.Workflows.WorkflowRun
      |> Repo.scoped(scope)
      |> where([r], r.inserted_at >= ^since)
      |> join(:inner, [r], w in Flux.Workflows.Workflow, on: r.workflow_id == w.id)
      |> select([r, w], %{workflow_id: r.workflow_id, name: w.name, usage: r.usage})
      |> Repo.all()

    runs
    |> Enum.group_by(& &1.workflow_id)
    |> Enum.map(fn {workflow_id, group} ->
      %{
        workflow_id: workflow_id,
        name: hd(group).name,
        runs: length(group),
        tokens:
          Enum.sum(
            for row <- group,
                do: (row.usage["input_tokens"] || 0) + (row.usage["output_tokens"] || 0)
          ),
        cost: Enum.sum(for row <- group, do: row.usage["estimated_cost_usd"] || 0.0)
      }
    end)
    |> Enum.sort_by(&(-&1.cost))
  end

  @doc "The cost table as CSV rows (header + one line per flux)."
  def flux_costs_csv(%Scope{} = scope, days \\ 30) do
    rows =
      for row <- flux_costs(scope, days) do
        Enum.join(
          [row.name, row.runs, row.tokens, :erlang.float_to_binary(row.cost * 1.0, decimals: 6)],
          ","
        )
      end

    Enum.join(["flux,runs,tokens,estimated_cost_usd" | rows], "\n") <> "\n"
  end

  defp token_totals(scope, since) do
    Message
    |> Repo.scoped(scope)
    |> where([m], m.role == :assistant and m.inserted_at >= ^since)
    |> select([m], %{
      replies: count(m.id),
      input: sum(fragment("coalesce((? ->> 'input_tokens')::bigint, 0)", m.usage)),
      output: sum(fragment("coalesce((? ->> 'output_tokens')::bigint, 0)", m.usage))
    })
    |> Repo.one()
    |> normalize_sums()
  end

  defp daily_tokens(scope, since) do
    Message
    |> Repo.scoped(scope)
    |> where([m], m.role == :assistant and m.inserted_at >= ^since)
    |> group_by([m], fragment("date(?)", m.inserted_at))
    |> order_by([m], desc: fragment("date(?)", m.inserted_at))
    |> select([m], %{
      day: fragment("date(?)", m.inserted_at),
      replies: count(m.id),
      input: sum(fragment("coalesce((? ->> 'input_tokens')::bigint, 0)", m.usage)),
      output: sum(fragment("coalesce((? ->> 'output_tokens')::bigint, 0)", m.usage))
    })
    |> Repo.all()
    |> Enum.map(&normalize_sums/1)
  end

  defp run_token_totals(scope, since) do
    WorkflowRun
    |> Repo.scoped(scope)
    |> where([r], r.inserted_at >= ^since)
    |> select([r], %{
      input: sum(fragment("coalesce((? ->> 'input_tokens')::bigint, 0)", r.usage)),
      output: sum(fragment("coalesce((? ->> 'output_tokens')::bigint, 0)", r.usage)),
      cost: sum(fragment("coalesce((? ->> 'estimated_cost_usd')::numeric, 0)", r.usage))
    })
    |> Repo.one()
    |> then(fn row ->
      %{
        input: to_int(row.input),
        output: to_int(row.output),
        estimated_cost_usd: to_float(row.cost)
      }
    end)
  end

  defp run_counts(scope, since) do
    WorkflowRun
    |> Repo.scoped(scope)
    |> where([r], r.inserted_at >= ^since)
    |> group_by([r], r.status)
    |> select([r], {r.status, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp top_apps(scope, since, limit \\ 5) do
    Message
    |> Repo.scoped(scope)
    |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
    |> join(:inner, [m, c], a in Flux.Chat.App, on: c.app_id == a.id)
    |> where([m], m.role == :assistant and m.inserted_at >= ^since)
    |> group_by([m, c, a], a.name)
    |> order_by([m],
      desc:
        sum(
          fragment(
            "coalesce((? ->> 'input_tokens')::bigint, 0) + coalesce((? ->> 'output_tokens')::bigint, 0)",
            m.usage,
            m.usage
          )
        )
    )
    |> limit(^limit)
    |> select([m, c, a], %{
      name: a.name,
      replies: count(m.id),
      tokens:
        sum(
          fragment(
            "coalesce((? ->> 'input_tokens')::bigint, 0) + coalesce((? ->> 'output_tokens')::bigint, 0)",
            m.usage,
            m.usage
          )
        )
    })
    |> Repo.all()
    |> Enum.map(fn row -> %{row | tokens: to_int(row.tokens)} end)
  end

  defp storage_bytes(scope) do
    Flux.Chat.UploadedFile
    |> Repo.scoped(scope)
    |> select([f], sum(f.size))
    |> Repo.one()
    |> to_int()
  end

  @doc """
  Getting-started progress for the dashboard checklist. Each step is
  `%{key, done}`; the card hides once everything is done.
  """
  def onboarding(%Scope{} = scope) do
    workspace_id = Scope.workspace_id(scope)

    count_of = fn table, extra ->
      base = from(t in table, where: t.workspace_id == type(^workspace_id, :binary_id))
      extra.(base) |> select([t], count(t.id)) |> Repo.one()
    end

    plain = fn table -> count_of.(table, & &1) end

    provider_ids =
      Flux.Providers.list_provider_plugins()
      |> Enum.map(&to_string(&1.id))
      |> MapSet.new()
      |> MapSet.delete("echo")

    provider_done =
      Flux.Tools.list_installed_plugin_ids(scope)
      |> Enum.any?(&MapSet.member?(provider_ids, to_string(&1)))

    runs = plain.("workflow_runs")
    replies = count_of.("conversations", & &1)

    [
      %{key: :provider, done: provider_done},
      %{key: :flux, done: count_of.("workflows", &where(&1, [t], is_nil(t.deleted_at))) > 0},
      %{key: :publish, done: plain.("workflow_versions") > 0},
      %{key: :knowledge, done: count_of.("datasets", &where(&1, [t], is_nil(t.deleted_at))) > 0},
      %{key: :run, done: runs + replies > 0},
      %{key: :invite, done: plain.("memberships") > 1}
    ]
  end

  defp knowledge_counts(scope) do
    workspace_id = Scope.workspace_id(scope)

    count_of = fn table ->
      from(t in table, where: t.workspace_id == type(^workspace_id, :binary_id))
      |> select([t], count(t.id))
      |> Repo.one()
    end

    %{
      datasets: count_of.("datasets"),
      documents: count_of.("rag_documents"),
      segments: count_of.("rag_segments")
    }
  end

  defp normalize_sums(row) do
    row
    |> Map.update!(:input, &to_int/1)
    |> Map.update!(:output, &to_int/1)
  end

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp to_int(n) when is_integer(n), do: n

  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_float(n) when is_number(n), do: n * 1.0
end
