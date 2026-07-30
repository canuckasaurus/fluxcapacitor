defmodule Flux.Release do
  @moduledoc """
  Tasks run inside a release, where Mix is unavailable:

      bin/flux eval "Flux.Release.migrate()"
      bin/flux eval "Flux.Release.create_admin(\\"me@example.com\\", \\"secret\\", \\"My WS\\")"
  """

  @app :flux

  alias Flux.Accounts
  alias Flux.Accounts.Account
  alias Flux.Repo

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _fun_return, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _fun_return, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Seeds (or repairs) a confirmed, password-bearing account with a workspace —
  the local-deploy substitute for magic-link email delivery.
  """
  def create_admin(email, password, workspace_name \\ "Workspace") do
    start_app()

    account =
      case Repo.get_by(Account, [email: email], skip_workspace_guard: true) do
        nil ->
          {:ok, account} = Accounts.register_account(%{email: email})
          account

        existing ->
          existing
      end

    account =
      account
      |> Account.confirm_changeset()
      |> Repo.update!()

    account =
      account
      |> Account.password_changeset(%{password: password})
      |> Repo.update!()

    if Accounts.scope_for(account).workspace == nil do
      {:ok, _workspace_and_membership} =
        Accounts.create_workspace(account, %{name: workspace_name})
    end

    IO.puts("admin ready: #{account.email}")
    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_loaded(@app)
  end

  defp start_app do
    Application.ensure_all_started(@app)
  end
end
