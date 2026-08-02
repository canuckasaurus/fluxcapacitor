defmodule Flux.Interviews do
  @moduledoc """
  Reusable interview definitions — ordered question sets an interview
  node presents as one form when a run pauses. The docassemble-style
  "input templates": author once, plug into any flux.

  Questions are maps: `name` (variable-safe), `label`, `type`
  (#{inspect(~w(text textarea number select boolean))}), `required`,
  `help`, and `options` (select only). `validate_answers/2` is the one
  place answers are checked, shared by the console, sites, and `/v1`.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.RBAC
  alias Flux.Repo

  @question_types ~w(text textarea number select boolean)

  defmodule Interview do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "interviews" do
      belongs_to :workspace, Flux.Accounts.Workspace
      field :name, :string
      field :description, :string
      field :intro, :string
      field :questions, {:array, :map}, default: []

      timestamps(type: :utc_datetime)
    end

    def changeset(interview, attrs) do
      interview
      |> cast(attrs, [:name, :description, :intro, :questions])
      |> validate_required([:name])
      |> validate_length(:name, min: 1, max: 120)
      |> update_change(:questions, &Flux.Interviews.normalize_questions/1)
      |> validate_change(:questions, fn :questions, questions ->
        case Flux.Interviews.questions_error(questions) do
          nil -> []
          message -> [questions: message]
        end
      end)
      |> unique_constraint([:workspace_id, :name])
    end
  end

  def question_types, do: @question_types

  def list(%Scope{} = scope) do
    Interview |> Repo.scoped(scope) |> order_by([i], asc: i.name) |> Repo.all()
  end

  def get(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(Interview, id: ^id), scope)) || {:error, :not_found}
  end

  def create(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         {:ok, interview} <-
           %Interview{workspace_id: Scope.workspace_id(scope)}
           |> Interview.changeset(attrs)
           |> Repo.insert() do
      audit(scope, "interview.create", interview)
      {:ok, interview}
    end
  end

  def update(%Scope{} = scope, %Interview{} = interview, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- interview.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, updated} <- interview |> Interview.changeset(attrs) |> Repo.update() do
      audit(scope, "interview.update", updated)
      {:ok, updated}
    end
  end

  def delete(%Scope{} = scope, id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Interview{} = interview <-
           Repo.one(Repo.scoped(where(Interview, id: ^id), scope)) || {:error, :not_found},
         {:ok, deleted} <- Repo.delete(interview) do
      audit(scope, "interview.delete", interview)
      {:ok, deleted}
    end
  end

  defp audit(scope, action, interview) do
    Flux.Audit.record(scope, action,
      resource_type: "interview",
      resource_id: interview.id,
      metadata: %{"name" => interview.name}
    )
  end

  @doc "Definition lookup for the engine's fetch_interview capability."
  def fetch(workspace_id, interview_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(to_string(interview_id)),
         %Interview{} = interview <-
           Repo.one(
             from(i in Interview,
               where: i.workspace_id == ^workspace_id and i.id == ^interview_id
             )
           ) do
      {:ok,
       %{
         "name" => interview.name,
         "intro" => interview.intro || "",
         "questions" => interview.questions
       }}
    else
      _missing -> {:error, "interview not found"}
    end
  end

  @doc """
  Checks a submitted answer map against an interview's questions:
  required presence, number parsing, select membership, boolean
  coercion. Returns `{:ok, answers}` (typed, defaulted) or
  `{:error, %{name => message}}`.
  """
  def validate_answers(questions, params) when is_list(questions) and is_map(params) do
    {answers, errors} =
      Enum.reduce(questions, {%{}, %{}}, fn question, {answers, errors} ->
        name = question["name"]
        raw = params[name]

        case check_answer(question, raw) do
          {:ok, value} -> {Map.put(answers, name, value), errors}
          {:error, message} -> {answers, Map.put(errors, name, message)}
        end
      end)

    if errors == %{}, do: {:ok, answers}, else: {:error, errors}
  end

  defp check_answer(%{"type" => "boolean"}, raw),
    do: {:ok, to_string(raw) in ~w(true on yes 1)}

  defp check_answer(question, raw) do
    text = raw |> to_string() |> String.trim()

    cond do
      text == "" and question["required"] == true -> {:error, "is required"}
      text == "" -> {:ok, ""}
      true -> check_type(question, text)
    end
  end

  defp check_type(%{"type" => "number"}, text) do
    case Float.parse(text) do
      {number, ""} -> {:ok, trim_float(number)}
      _invalid -> {:error, "must be a number"}
    end
  end

  defp check_type(%{"type" => "select", "options" => options}, text) do
    if text in List.wrap(options) do
      {:ok, text}
    else
      {:error, "must be one of: " <> Enum.join(List.wrap(options), ", ")}
    end
  end

  defp check_type(_question, text), do: {:ok, text}

  defp trim_float(number) do
    truncated = trunc(number)
    if truncated == number, do: truncated, else: number
  end

  @doc false
  def normalize_questions(questions) do
    questions
    |> List.wrap()
    |> Enum.map(fn question ->
      name = question["name"] |> to_string() |> String.trim()
      label = question["label"] |> to_string() |> String.trim()

      %{
        "name" => name,
        "label" => (label != "" && label) || name,
        "type" => (question["type"] in @question_types && question["type"]) || "text",
        "required" => question["required"] in [true, "true", "on"],
        "help" => to_string(question["help"] || ""),
        "options" =>
          question["options"]
          |> case do
            list when is_list(list) -> list
            csv -> csv |> to_string() |> String.split(",")
          end
          |> Enum.map(&String.trim(to_string(&1)))
          |> Enum.reject(&(&1 == ""))
      }
    end)
    |> Enum.reject(&(&1["name"] == ""))
  end

  @doc false
  def questions_error(questions) do
    names = Enum.map(questions, & &1["name"])

    cond do
      questions == [] ->
        "needs at least one question"

      Enum.any?(names, &(not Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, &1))) ->
        "question names must be variable-safe (letters, digits, underscores)"

      length(Enum.uniq(names)) != length(names) ->
        "question names must be unique"

      Enum.any?(questions, &(&1["type"] == "select" and &1["options"] == [])) ->
        "select questions need options"

      true ->
        nil
    end
  end
end
