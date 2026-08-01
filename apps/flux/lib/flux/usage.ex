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
      top_apps: top_apps(scope, since),
      storage_bytes: storage_bytes(scope),
      knowledge: knowledge_counts(scope)
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
end
