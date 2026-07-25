defmodule DifyWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DifyWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint DifyWeb.Endpoint

      use DifyWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import DifyWeb.ConnCase
    end
  end

  setup tags do
    Dify.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in accounts.

      setup :register_and_log_in_account

  It stores an updated connection and a registered account in the
  test context.
  """
  def register_and_log_in_account(%{conn: conn} = context) do
    account = Dify.AccountsFixtures.account_fixture()
    scope = Dify.Accounts.Scope.for_account(account)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_account(conn, account, opts), account: account, scope: scope}
  end

  @doc """
  Logs the given `account` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_account(conn, account, opts \\ []) do
    token = Dify.Accounts.generate_account_session_token(account)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:account_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    Dify.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
