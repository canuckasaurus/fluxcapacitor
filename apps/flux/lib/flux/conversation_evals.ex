defmodule Flux.ConversationEvals do
  @moduledoc """
  Scripted multi-turn eval dialogues for chat apps.

  Each eval is a list of user turns replayed in order through the app's
  model (or bound chatflow) via the stateless completion paths — nothing
  is persisted to conversations. The finished transcript is judged as a
  whole by an LLM against the eval's `expectation`, so behaviors that
  only show up across turns (memory, tone drift, refusing then caving)
  are scoreable.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Chat
  alias Flux.Chat.App
  alias Flux.RBAC
  alias Flux.Repo

  defmodule ConversationEval do
    @moduledoc "One scripted dialogue with its latest score."
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "conversation_evals" do
      belongs_to :workspace, Flux.Accounts.Workspace
      belongs_to :app, Flux.Chat.App

      field :name, :string
      field :turns, {:array, :string}, default: []
      field :expectation, :string
      field :judge, :string
      field :schedule, :string

      field :last_score, :float
      field :last_reason, :string
      field :last_transcript, {:array, :map}, default: []
      field :last_run_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    def changeset(eval, attrs) do
      eval
      |> cast(attrs, [:name, :turns, :expectation, :judge, :schedule])
      |> validate_required([:name, :expectation])
      |> validate_length(:name, min: 1, max: 255)
      |> update_change(:turns, fn turns ->
        turns |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end)
      |> validate_turns()
      |> validate_schedule()
    end

    # Same parser as every other cron field in the platform.
    defp validate_schedule(changeset) do
      case get_change(changeset, :schedule) do
        nil ->
          changeset

        "" ->
          put_change(changeset, :schedule, nil)

        schedule ->
          case Oban.Cron.Expression.parse(schedule) do
            {:ok, _expression} ->
              changeset

            {:error, _reason} ->
              add_error(changeset, :schedule, "is not a valid cron expression")
          end
      end
    end

    defp validate_turns(changeset) do
      case get_field(changeset, :turns) do
        [_at_least_one | _] = turns when length(turns) <= 20 ->
          changeset

        [_too | _many] ->
          add_error(changeset, :turns, "keep scripted dialogues to 20 turns or fewer")

        _empty ->
          add_error(changeset, :turns, "needs at least one user turn")
      end
    end
  end

  @doc """
  Minute tick (via the schedule worker): re-runs every conversation eval
  whose cron matches this minute. Score drops notify through
  `run_conversation_eval/2` as usual.
  """
  def run_scheduled(now \\ DateTime.utc_now(:second)) do
    minute_start = %{now | second: 0}

    evals =
      Repo.all(
        where(ConversationEval, [e], not is_nil(e.schedule)),
        skip_workspace_guard: true
      )

    for eval <- evals,
        cron_due?(eval.schedule, now),
        is_nil(eval.last_run_at) or DateTime.compare(eval.last_run_at, minute_start) == :lt do
      run_conversation_eval(worker_scope(eval.workspace_id), eval.id)
    end

    :ok
  end

  defp cron_due?(schedule, now) do
    case Oban.Cron.Expression.parse(schedule) do
      {:ok, expression} -> Oban.Cron.Expression.now?(expression, now)
      {:error, _reason} -> false
    end
  end

  defp worker_scope(workspace_id) do
    %Scope{
      workspace: %Flux.Accounts.Workspace{id: workspace_id},
      membership: %Flux.Accounts.Membership{workspace_id: workspace_id, role: :editor}
    }
  end

  def list_conversation_evals(%Scope{} = scope, app_id) do
    ConversationEval
    |> where(app_id: ^app_id)
    |> Repo.scoped(scope)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  def get_conversation_eval(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(ConversationEval, id: ^id), scope)) || {:error, :not_found}
  end

  def create_conversation_eval(%Scope{} = scope, %App{} = app, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- app.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      %ConversationEval{workspace_id: app.workspace_id, app_id: app.id}
      |> ConversationEval.changeset(attrs)
      |> Repo.insert()
    end
  end

  def delete_conversation_eval(%Scope{} = scope, id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %ConversationEval{} = eval <- get_conversation_eval(scope, id) do
      Repo.delete(eval)
    end
  end

  @doc """
  Plays the scripted turns through the app and judges the transcript.
  Persists `last_score`/`last_reason`/`last_transcript` on the eval and
  returns `{:ok, updated}`. A turn that errors scores 0.0 with the
  failure as the reason (the partial transcript is still kept). A score
  drop from the previous run raises an `eval_regressed` notification.
  """
  def run_conversation_eval(%Scope{} = scope, id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %ConversationEval{} = eval <- get_conversation_eval(scope, id),
         %App{} = app <- Chat.get_app(scope, eval.app_id) do
      {score, reason, transcript} =
        case play_turns(app, eval.turns) do
          {:ok, transcript} ->
            {score, reason} = judge(eval, transcript)
            {score, reason, transcript}

          {:error, error, partial} ->
            {0.0, "a turn failed: #{inspect(error)}", partial}
        end

      previous = eval.last_score

      updated =
        eval
        |> Ecto.Changeset.change(
          last_score: score,
          last_reason: String.slice(to_string(reason), 0, 500),
          last_transcript:
            Enum.map(transcript, fn message ->
              %{"role" => to_string(message.role), "content" => message.content}
            end),
          last_run_at: DateTime.utc_now(:second)
        )
        |> Repo.update!()

      if is_number(previous) and score < previous do
        Flux.Notifications.notify(
          eval.workspace_id,
          "eval_regressed",
          "Conversation eval \"#{eval.name}\" regressed: #{previous} → #{score}",
          "/console/apps/#{eval.app_id}/monitor"
        )
      end

      {:ok, updated}
    end
  end

  # Fold the scripted user turns through the app's stateless completion,
  # accumulating the transcript; a failed turn halts with what we have.
  defp play_turns(app, turns) do
    Enum.reduce_while(turns, {:ok, []}, fn turn, {:ok, messages} ->
      messages = messages ++ [%{role: :user, content: turn}]

      case completion(app, messages) do
        {:ok, %{content: content}, _model} ->
          {:cont, {:ok, messages ++ [%{role: :assistant, content: to_string(content)}]}}

        {:error, reason} ->
          {:halt, {:error, reason, messages}}

        other ->
          {:halt, {:error, other, messages}}
      end
    end)
  end

  defp completion(%App{mode: :advanced_chat} = app, messages),
    do: Chat.stateless_chatflow_completion(app, messages, fn _chunk -> :ok end)

  defp completion(app, messages),
    do: Chat.stateless_completion(app, messages, fn _chunk -> :ok end)

  defp judge(eval, transcript) do
    transcript_text =
      Enum.map_join(transcript, "\n", fn message -> "#{message.role}: #{message.content}" end)

    prompt = """
    You are grading a scripted multi-turn conversation with an AI assistant.

    Expectation (what a good dialogue looks like): #{eval.expectation}

    Transcript:
    #{transcript_text}

    Score how well the assistant's side of the dialogue satisfies the
    expectation on a 0.0–1.0 scale (1.0 = fully satisfies). Reply with
    ONLY a JSON object: {"score": <number>, "reason": "<one sentence>"}
    """

    case Flux.Evals.judge_llm(eval.workspace_id, eval.judge, [%{role: :user, content: prompt}]) do
      {:ok, reply} -> Flux.Evals.parse_judge_reply(reply)
      {:error, :no_default_model} -> {0.0, "no workspace default model to judge with"}
      {:error, reason} -> {0.0, "judge errored: #{inspect(reason)}"}
    end
  end
end
