defmodule FluxWeb.InterviewsTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Interviews

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Intake WS"})
    scope = Accounts.scope_for(account)
    %{conn: log_in_account(conn, account), scope: scope}
  end

  @questions [
    %{"name" => "client_name", "label" => "Client name", "type" => "text", "required" => true},
    %{"name" => "age", "label" => "Age", "type" => "number", "required" => true},
    %{
      "name" => "state",
      "label" => "State",
      "type" => "select",
      "required" => true,
      "options" => ["CA", "NY"]
    },
    %{"name" => "urgent", "label" => "Urgent?", "type" => "boolean"}
  ]

  test "CRUD with question validation", %{scope: scope} do
    assert {:ok, interview} =
             Interviews.create(scope, %{"name" => "Intake", "questions" => @questions})

    assert [%{"name" => "client_name", "required" => true} | _rest] = interview.questions

    # Bad question names are rejected.
    assert {:error, changeset} =
             Interviews.create(scope, %{
               "name" => "Bad",
               "questions" => [%{"name" => "no spaces allowed"}]
             })

    assert {"question names must be variable-safe" <> _rest, _opts} =
             changeset.errors[:questions]

    # Select without options is rejected.
    assert {:error, _changeset} =
             Interviews.create(scope, %{
               "name" => "Bad select",
               "questions" => [%{"name" => "x", "type" => "select", "options" => []}]
             })

    assert {:ok, _updated} =
             Interviews.update(scope, interview, %{"description" => "Standard intake"})

    assert {:ok, _} = Interviews.delete(scope, interview.id)
    assert Interviews.list(scope) == []
  end

  test "validate_answers types, requires, and coerces", %{scope: _scope} do
    assert {:ok, answers} =
             Interviews.validate_answers(
               Interviews.normalize_questions(@questions),
               %{"client_name" => "Clara", "age" => "34", "state" => "CA", "urgent" => "on"}
             )

    assert answers == %{"client_name" => "Clara", "age" => 34, "state" => "CA", "urgent" => true}

    assert {:error, errors} =
             Interviews.validate_answers(
               Interviews.normalize_questions(@questions),
               %{"age" => "not a number", "state" => "TX"}
             )

    assert errors["client_name"] == "is required"
    assert errors["age"] == "must be a number"
    assert errors["state"] =~ "must be one of"
  end

  test "date, email, and regex-pattern questions validate", %{scope: scope} do
    questions =
      Interviews.normalize_questions([
        %{"name" => "dob", "type" => "date", "required" => true},
        %{"name" => "contact", "type" => "email", "required" => true},
        %{
          "name" => "file_no",
          "type" => "text",
          "pattern" => "^F-\\d{4}$",
          "pattern_hint" => "must look like F-1234"
        }
      ])

    assert {:ok, answers} =
             Interviews.validate_answers(questions, %{
               "dob" => "1985-10-26",
               "contact" => "doc@hillvalley.edu",
               "file_no" => "F-0088"
             })

    assert answers["dob"] == "1985-10-26"

    assert {:error, errors} =
             Interviews.validate_answers(questions, %{
               "dob" => "Oct 26",
               "contact" => "not-an-email",
               "file_no" => "88"
             })

    assert errors["dob"] =~ "YYYY-MM-DD"
    assert errors["contact"] =~ "email"
    assert errors["file_no"] == "must look like F-1234"

    # A pattern that doesn't compile is rejected at save time.
    assert {:error, changeset} =
             Interviews.create(scope, %{
               "name" => "Bad pattern",
               "questions" => [%{"name" => "x", "pattern" => "([unclosed"}]
             })

    assert {"a regex pattern does not compile", _opts} = changeset.errors[:questions]
  end

  test "the library page builds an interview", %{conn: conn, scope: scope} do
    {:ok, lv, html} = live(conn, ~p"/console/interviews")
    assert html =~ "Interviews"

    lv |> element("button", "New interview") |> render_click()

    lv
    |> form("#interview-form", %{
      "name" => "Quick intake",
      "q" => %{
        "0" => %{"name" => "matter", "label" => "What is this about?", "type" => "textarea"}
      }
    })
    |> render_submit()

    assert [interview] = Interviews.list(scope)
    assert interview.name == "Quick intake"
    assert [%{"name" => "matter", "type" => "textarea"}] = interview.questions
  end
end
