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
