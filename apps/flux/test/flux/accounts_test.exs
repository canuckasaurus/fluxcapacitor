defmodule Flux.AccountsTest do
  use Flux.DataCase

  alias Flux.Accounts

  import Flux.AccountsFixtures
  alias Flux.Accounts.{Account, AccountToken}

  describe "get_account_by_email/1" do
    test "does not return the account if the email does not exist" do
      refute Accounts.get_account_by_email("unknown@example.com")
    end

    test "returns the account if the email exists" do
      %{id: id} = account = account_fixture()
      assert %Account{id: ^id} = Accounts.get_account_by_email(account.email)
    end
  end

  describe "get_account_by_email_and_password/2" do
    test "does not return the account if the email does not exist" do
      refute Accounts.get_account_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the account if the password is not valid" do
      account = account_fixture() |> set_password()
      refute Accounts.get_account_by_email_and_password(account.email, "invalid")
    end

    test "returns the account if the email and password are valid" do
      %{id: id} = account = account_fixture() |> set_password()

      assert %Account{id: ^id} =
               Accounts.get_account_by_email_and_password(account.email, valid_account_password())
    end
  end

  describe "get_account!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_account!("11111111-1111-1111-1111-111111111111")
      end
    end

    test "returns the account with the given id" do
      %{id: id} = account = account_fixture()
      assert %Account{id: ^id} = Accounts.get_account!(account.id)
    end
  end

  describe "register_account/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_account(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_account(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_account(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = account_fixture()
      {:error, changeset} = Accounts.register_account(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_account(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers accounts without password" do
      email = unique_account_email()
      {:ok, account} = Accounts.register_account(valid_account_attributes(email: email))
      assert account.email == email
      assert is_nil(account.hashed_password)
      assert is_nil(account.confirmed_at)
      assert is_nil(account.password)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = NaiveDateTime.utc_now()

      assert Accounts.sudo_mode?(%Account{authenticated_at: NaiveDateTime.utc_now()})
      assert Accounts.sudo_mode?(%Account{authenticated_at: NaiveDateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%Account{authenticated_at: NaiveDateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %Account{authenticated_at: NaiveDateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%Account{})
    end
  end

  describe "change_account_email/3" do
    test "returns a account changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_account_email(%Account{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_account_update_email_instructions/3" do
    setup do
      %{account: account_fixture()}
    end

    test "sends token through notification", %{account: account} do
      token =
        extract_account_token(fn url ->
          Accounts.deliver_account_update_email_instructions(account, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert account_token = Repo.get_by(AccountToken, token: :crypto.hash(:sha256, token))
      assert account_token.account_id == account.id
      assert account_token.sent_to == account.email
      assert account_token.context == "change:current@example.com"
    end
  end

  describe "update_account_email/2" do
    setup do
      account = unconfirmed_account_fixture()
      email = unique_account_email()

      token =
        extract_account_token(fn url ->
          Accounts.deliver_account_update_email_instructions(
            %{account | email: email},
            account.email,
            url
          )
        end)

      %{account: account, token: token, email: email}
    end

    test "updates the email with a valid token", %{account: account, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_account_email(account, token)
      changed_account = Repo.get!(Account, account.id)
      assert changed_account.email != account.email
      assert changed_account.email == email
      refute Repo.get_by(AccountToken, account_id: account.id)
    end

    test "does not update email with invalid token", %{account: account} do
      assert Accounts.update_account_email(account, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(Account, account.id).email == account.email
      assert Repo.get_by(AccountToken, account_id: account.id)
    end

    test "does not update email if account email changed", %{account: account, token: token} do
      assert Accounts.update_account_email(%{account | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Account, account.id).email == account.email
      assert Repo.get_by(AccountToken, account_id: account.id)
    end

    test "does not update email if token expired", %{account: account, token: token} do
      {1, nil} = Repo.update_all(AccountToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_account_email(account, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Account, account.id).email == account.email
      assert Repo.get_by(AccountToken, account_id: account.id)
    end
  end

  describe "change_account_password/3" do
    test "returns a account changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_account_password(%Account{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_account_password(
          %Account{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_account_password/2" do
    setup do
      %{account: account_fixture()}
    end

    test "validates password", %{account: account} do
      {:error, changeset} =
        Accounts.update_account_password(account, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{account: account} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_account_password(account, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{account: account} do
      {:ok, {account, expired_tokens}} =
        Accounts.update_account_password(account, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(account.password)
      assert Accounts.get_account_by_email_and_password(account.email, "new valid password")
    end

    test "deletes all tokens for the given account", %{account: account} do
      _ = Accounts.generate_account_session_token(account)

      {:ok, {_, _}} =
        Accounts.update_account_password(account, %{
          password: "new valid password"
        })

      refute Repo.get_by(AccountToken, account_id: account.id)
    end
  end

  describe "generate_account_session_token/1" do
    setup do
      %{account: account_fixture()}
    end

    test "generates a token", %{account: account} do
      token = Accounts.generate_account_session_token(account)
      assert account_token = Repo.get_by(AccountToken, token: token)
      assert account_token.context == "session"
      assert account_token.authenticated_at != nil

      # Creating the same token for another account should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%AccountToken{
          token: account_token.token,
          account_id: account_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given account in new token", %{account: account} do
      account = %{
        account
        | authenticated_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600)
      }

      token = Accounts.generate_account_session_token(account)
      assert account_token = Repo.get_by(AccountToken, token: token)
      assert account_token.authenticated_at == account.authenticated_at
      assert NaiveDateTime.compare(account_token.inserted_at, account.authenticated_at) == :gt
    end
  end

  describe "get_account_by_session_token/1" do
    setup do
      account = account_fixture()
      token = Accounts.generate_account_session_token(account)
      %{account: account, token: token}
    end

    test "returns account by token", %{account: account, token: token} do
      assert {session_account, token_inserted_at} = Accounts.get_account_by_session_token(token)
      assert session_account.id == account.id
      assert session_account.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return account for invalid token" do
      refute Accounts.get_account_by_session_token("oops")
    end

    test "does not return account for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(AccountToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_account_by_session_token(token)
    end
  end

  describe "get_account_by_magic_link_token/1" do
    setup do
      account = account_fixture()
      {encoded_token, _hashed_token} = generate_account_magic_link_token(account)
      %{account: account, token: encoded_token}
    end

    test "returns account by token", %{account: account, token: token} do
      assert session_account = Accounts.get_account_by_magic_link_token(token)
      assert session_account.id == account.id
    end

    test "does not return account for invalid token" do
      refute Accounts.get_account_by_magic_link_token("oops")
    end

    test "does not return account for expired token", %{token: token} do
      {1, nil} = Repo.update_all(AccountToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_account_by_magic_link_token(token)
    end
  end

  describe "login_account_by_magic_link/1" do
    test "confirms account and expires tokens" do
      account = unconfirmed_account_fixture()
      refute account.confirmed_at
      {encoded_token, hashed_token} = generate_account_magic_link_token(account)

      assert {:ok, {account, [%{token: ^hashed_token}]}} =
               Accounts.login_account_by_magic_link(encoded_token)

      assert account.confirmed_at
    end

    test "returns account and (deleted) token for confirmed account" do
      account = account_fixture()
      assert account.confirmed_at
      {encoded_token, _hashed_token} = generate_account_magic_link_token(account)
      assert {:ok, {^account, []}} = Accounts.login_account_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_account_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed account has password set" do
      account = unconfirmed_account_fixture()
      {1, nil} = Repo.update_all(Account, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_account_magic_link_token(account)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_account_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_account_session_token/1" do
    test "deletes the token" do
      account = account_fixture()
      token = Accounts.generate_account_session_token(account)
      assert Accounts.delete_account_session_token(token) == :ok
      refute Accounts.get_account_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{account: unconfirmed_account_fixture()}
    end

    test "sends token through notification", %{account: account} do
      token =
        extract_account_token(fn url ->
          Accounts.deliver_login_instructions(account, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert account_token = Repo.get_by(AccountToken, token: :crypto.hash(:sha256, token))
      assert account_token.account_id == account.id
      assert account_token.sent_to == account.email
      assert account_token.context == "login"
    end
  end

  describe "inspect/2 for the Account module" do
    test "does not include password" do
      refute inspect(%Account{password: "123456"}) =~ "password: \"123456\""
    end
  end
end
