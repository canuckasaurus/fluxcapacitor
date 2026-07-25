defmodule Flux.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Flux.Accounts` context.
  """

  import Ecto.Query

  alias Flux.Accounts
  alias Flux.Accounts.Scope

  def unique_account_email, do: "account#{System.unique_integer()}@example.com"
  def valid_account_password, do: "hello world!"

  def valid_account_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_account_email()
    })
  end

  def unconfirmed_account_fixture(attrs \\ %{}) do
    {:ok, account} =
      attrs
      |> valid_account_attributes()
      |> Accounts.register_account()

    account
  end

  def account_fixture(attrs \\ %{}) do
    account = unconfirmed_account_fixture(attrs)

    token =
      extract_account_token(fn url ->
        Accounts.deliver_login_instructions(account, url)
      end)

    {:ok, {account, _expired_tokens}} =
      Accounts.login_account_by_magic_link(token)

    account
  end

  def account_scope_fixture do
    account = account_fixture()
    account_scope_fixture(account)
  end

  def account_scope_fixture(account) do
    Scope.for_account(account)
  end

  def set_password(account) do
    {:ok, {account, _expired_tokens}} =
      Accounts.update_account_password(account, %{password: valid_account_password()})

    account
  end

  def extract_account_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Flux.Repo.update_all(
      from(t in Accounts.AccountToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_account_magic_link_token(account) do
    {encoded_token, account_token} = Accounts.AccountToken.build_email_token(account, "login")
    Flux.Repo.insert!(account_token)
    {encoded_token, account_token.token}
  end

  def offset_account_token(token, amount_to_add, unit) do
    dt = NaiveDateTime.add(NaiveDateTime.utc_now(:second), amount_to_add, unit)

    Flux.Repo.update_all(
      from(ut in Accounts.AccountToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
