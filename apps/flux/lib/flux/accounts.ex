defmodule Flux.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Flux.Repo

  alias Flux.Accounts.{Account, AccountNotifier, AccountToken}

  ## Database getters

  @doc """
  Gets a account by email.

  ## Examples

      iex> get_account_by_email("foo@example.com")
      %Account{}

      iex> get_account_by_email("unknown@example.com")
      nil

  """
  def get_account_by_email(email) when is_binary(email) do
    Repo.get_by(Account, email: email)
  end

  @doc """
  Gets a account by email and password.

  ## Examples

      iex> get_account_by_email_and_password("foo@example.com", "correct_password")
      %Account{}

      iex> get_account_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_account_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    account = Repo.get_by(Account, email: email)
    if Account.valid_password?(account, password), do: account
  end

  @doc """
  Gets a single account.

  Raises `Ecto.NoResultsError` if the Account does not exist.

  ## Examples

      iex> get_account!(123)
      %Account{}

      iex> get_account!(456)
      ** (Ecto.NoResultsError)

  """
  def get_account!(id), do: Repo.get!(Account, id)

  ## Account registration

  @doc """
  Registers a account.

  ## Examples

      iex> register_account(%{field: value})
      {:ok, %Account{}}

      iex> register_account(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_account(attrs) do
    %Account{}
    |> Account.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the account is in sudo mode.

  The account is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(account, minutes \\ -20)

  def sudo_mode?(%Account{authenticated_at: ts}, minutes) when is_struct(ts, NaiveDateTime) do
    NaiveDateTime.after?(ts, NaiveDateTime.utc_now() |> NaiveDateTime.add(minutes, :minute))
  end

  def sudo_mode?(_account, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the account email.

  See `Flux.Accounts.Account.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_account_email(account)
      %Ecto.Changeset{data: %Account{}}

  """
  def change_account_email(account, attrs \\ %{}, opts \\ []) do
    Account.email_changeset(account, attrs, opts)
  end

  @doc """
  Updates the account email using the given token.

  If the token matches, the account email is updated and the token is deleted.
  """
  def update_account_email(account, token) do
    context = "change:#{account.email}"

    Repo.transact(fn ->
      with {:ok, query} <- AccountToken.verify_change_email_token_query(token, context),
           %AccountToken{sent_to: email} <- Repo.one(query),
           {:ok, account} <- Repo.update(Account.email_changeset(account, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(
               from(AccountToken, where: [account_id: ^account.id, context: ^context])
             ) do
        {:ok, account}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the account password.

  See `Flux.Accounts.Account.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_account_password(account)
      %Ecto.Changeset{data: %Account{}}

  """
  def change_account_password(account, attrs \\ %{}, opts \\ []) do
    Account.password_changeset(account, attrs, opts)
  end

  @doc """
  Updates the account password.

  Returns a tuple with the updated account, as well as a list of expired tokens.

  ## Examples

      iex> update_account_password(account, %{password: ...})
      {:ok, {%Account{}, [...]}}

      iex> update_account_password(account, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_account_password(account, attrs) do
    account
    |> Account.password_changeset(attrs)
    |> update_account_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_account_session_token(account) do
    {token, account_token} = AccountToken.build_session_token(account)
    Repo.insert!(account_token)
    token
  end

  @doc """
  Gets the account with the given signed token.

  If the token is valid `{account, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_account_by_session_token(token) do
    {:ok, query} = AccountToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the account with the given magic link token.
  """
  def get_account_by_magic_link_token(token) do
    with {:ok, query} <- AccountToken.verify_magic_link_token_query(token),
         {account, _token} <- Repo.one(query) do
      account
    else
      _ -> nil
    end
  end

  @doc """
  Logs the account in by magic link.

  There are three cases to consider:

  1. The account has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The account has not confirmed their email and no password is set.
     In this case, the account gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The account has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_account_by_magic_link(token) do
    {:ok, query} = AccountToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%Account{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%Account{confirmed_at: nil} = account, _token} ->
        account
        |> Account.confirm_changeset()
        |> update_account_and_delete_all_tokens()

      {account, token} ->
        Repo.delete!(token)
        {:ok, {account, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given account.

  ## Examples

      iex> deliver_account_update_email_instructions(account, current_email, &url(~p"/accounts/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_account_update_email_instructions(
        %Account{} = account,
        current_email,
        update_email_url_fun
      )
      when is_function(update_email_url_fun, 1) do
    {encoded_token, account_token} =
      AccountToken.build_email_token(account, "change:#{current_email}")

    Repo.insert!(account_token)

    AccountNotifier.deliver_update_email_instructions(
      account,
      update_email_url_fun.(encoded_token)
    )
  end

  @doc """
  Delivers the magic link login instructions to the given account.
  """
  def deliver_login_instructions(%Account{} = account, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, account_token} = AccountToken.build_email_token(account, "login")
    Repo.insert!(account_token)
    AccountNotifier.deliver_login_instructions(account, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_account_session_token(token) do
    Repo.delete_all(from(AccountToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_account_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, account} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(AccountToken, account_id: account.id)

        Repo.delete_all(
          from(t in AccountToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))
        )

        {:ok, {account, tokens_to_expire}}
      end
    end)
  end

  ## Workspaces

  alias Flux.Accounts.{Invitation, Membership, Scope, Workspace}

  @doc """
  Creates a workspace and makes the creating account its owner, marking it as
  the account's current workspace.
  """
  def create_workspace(%Account{} = creator, attrs) do
    Repo.transact(fn ->
      with {:ok, workspace} <- %Workspace{} |> Workspace.changeset(attrs) |> Repo.insert(),
           :ok <- clear_current_membership(creator.id),
           {:ok, membership} <-
             %Membership{}
             |> Membership.changeset(%{
               workspace_id: workspace.id,
               account_id: creator.id,
               role: :owner,
               current: true
             })
             |> Repo.insert() do
        {:ok, {workspace, membership}}
      end
    end)
  end

  @doc "Lists all workspaces the account belongs to, with the account's membership preloaded."
  def list_workspaces(%Account{id: account_id}) do
    from(m in Membership,
      where: m.account_id == ^account_id,
      join: w in assoc(m, :workspace),
      where: w.status == "normal",
      order_by: [asc: w.name],
      select: {w, m}
    )
    |> Repo.all()
  end

  @doc """
  Returns the account's current workspace as `{workspace, membership}`,
  falling back to the first joined workspace when none is marked current.
  """
  def get_current_workspace(%Account{id: account_id}) do
    base =
      from(m in Membership,
        where: m.account_id == ^account_id,
        join: w in assoc(m, :workspace),
        where: w.status == "normal",
        select: {w, m}
      )

    result =
      Repo.one(from([m, w] in base, where: m.current == true, limit: 1)) ||
        Repo.one(from([m, w] in base, order_by: [asc: m.inserted_at], limit: 1))

    case result do
      {workspace, membership} -> {workspace, Repo.preload(membership, :custom_role)}
      nil -> nil
    end
  end

  @doc """
  Switches the account's current workspace. Returns `{:ok, {workspace, membership}}`
  or `{:error, :not_a_member}`.
  """
  def switch_workspace(%Account{id: account_id}, workspace_id) do
    case Repo.get_by(Membership, account_id: account_id, workspace_id: workspace_id) do
      nil ->
        {:error, :not_a_member}

      %Membership{} = membership ->
        Repo.transact(fn ->
          :ok = clear_current_membership(account_id)

          with {:ok, updated} <-
                 membership
                 |> Ecto.Changeset.change(
                   current: true,
                   last_active_at: DateTime.utc_now(:second)
                 )
                 |> Repo.update() do
            {:ok, {Repo.get!(Workspace, workspace_id), updated}}
          end
        end)
    end
  end

  @doc "Builds a scope with the account's current (or fallback) workspace attached."
  def scope_for(%Account{} = account) do
    scope = Scope.for_account(account)

    case get_current_workspace(account) do
      {workspace, membership} -> Scope.put_workspace(scope, workspace, membership)
      nil -> scope
    end
  end

  defp clear_current_membership(account_id) do
    Repo.update_all(
      from(m in Membership, where: m.account_id == ^account_id and m.current == true),
      set: [current: false]
    )

    :ok
  end

  ## Members and roles

  @doc "Lists the members of a workspace as `{account, membership}` tuples."
  def list_members(%Scope{} = scope) do
    from(m in Membership,
      where: m.workspace_id == ^Scope.workspace_id(scope),
      join: a in assoc(m, :account),
      order_by: [asc: m.inserted_at],
      select: {a, m}
    )
    |> Repo.all()
  end

  @doc """
  Updates a member's role. Owner role cannot be granted here — ownership moves
  only through the explicit transfer flow — and the current owner cannot be
  demoted, so a workspace always retains exactly one owner.
  """
  def update_member_role(%Scope{} = scope, %Membership{} = membership, new_role)
      when new_role in [:admin, :editor, :normal, :dataset_operator] do
    cond do
      not Flux.RBAC.can?(scope, :workspace_member_manage) -> {:error, :unauthorized}
      membership.workspace_id != Scope.workspace_id(scope) -> {:error, :not_found}
      membership.role == :owner -> {:error, :cannot_change_owner_role}
      true -> membership |> Ecto.Changeset.change(role: new_role) |> Repo.update()
    end
  end

  def update_member_role(%Scope{}, %Membership{}, _new_role), do: {:error, :invalid_role}

  @doc "Removes a member from the workspace. The owner cannot be removed."
  def remove_member(%Scope{} = scope, %Membership{} = membership) do
    cond do
      not Flux.RBAC.can?(scope, :workspace_member_manage) -> {:error, :unauthorized}
      membership.workspace_id != Scope.workspace_id(scope) -> {:error, :not_found}
      membership.role == :owner -> {:error, :cannot_remove_owner}
      membership.account_id == Scope.account_id(scope) -> {:error, :cannot_remove_self}
      true -> Repo.delete(membership)
    end
  end

  @doc """
  Transfers workspace ownership from the current owner (the caller) to another
  member. The previous owner becomes an admin.
  """
  def transfer_ownership(%Scope{} = scope, %Membership{} = new_owner) do
    workspace_id = Scope.workspace_id(scope)

    with true <- new_owner.workspace_id == workspace_id || {:error, :not_found},
         %Membership{role: :owner} = current_owner <-
           Repo.get_by(Membership,
             workspace_id: workspace_id,
             account_id: Scope.account_id(scope)
           ) ||
             {:error, :not_owner} do
      Repo.transact(fn ->
        with {:ok, demoted} <-
               current_owner |> Ecto.Changeset.change(role: :admin) |> Repo.update(),
             {:ok, promoted} <- new_owner |> Ecto.Changeset.change(role: :owner) |> Repo.update() do
          {:ok, {promoted, demoted}}
        end
      end)
    else
      %Membership{} -> {:error, :not_owner}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Invitations

  @doc """
  Invites an email address into the scope's workspace. Returns
  `{:ok, {invitation, raw_token}}`; the raw token is for the invite email and
  is never stored.
  """
  def create_invitation(%Scope{} = scope, attrs) do
    with :ok <- Flux.RBAC.authorize(scope, :workspace_member_manage) do
      do_create_invitation(scope, attrs)
    end
  end

  defp do_create_invitation(scope, attrs) do
    {raw_token, changeset} =
      Invitation.build(Scope.workspace_id(scope), Scope.account_id(scope), attrs)

    with {:ok, invitation} <- Repo.insert(changeset) do
      {:ok, {invitation, raw_token}}
    end
  end

  @doc "Invites many emails at once; returns `{oks, errors}` keyed by email."
  def create_invitations(%Scope{} = scope, emails, role) when is_list(emails) do
    emails
    |> Enum.map(&{&1, create_invitation(scope, %{email: &1, role: role})})
    |> Enum.split_with(fn {_email, result} -> match?({:ok, _}, result) end)
  end

  @doc "Lists pending (unaccepted, unexpired) invitations for the workspace."
  def list_pending_invitations(%Scope{} = scope) do
    now = DateTime.utc_now()

    from(i in Invitation,
      where:
        i.workspace_id == ^Scope.workspace_id(scope) and is_nil(i.accepted_at) and
          i.expires_at > ^now,
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Revokes a pending invitation."
  def revoke_invitation(%Scope{} = scope, invitation_id) do
    with :ok <- Flux.RBAC.authorize(scope, :workspace_member_manage) do
      do_revoke_invitation(scope, invitation_id)
    end
  end

  defp do_revoke_invitation(scope, invitation_id) do
    case Repo.get_by(Invitation, id: invitation_id, workspace_id: Scope.workspace_id(scope)) do
      nil -> {:error, :not_found}
      %Invitation{accepted_at: nil} = invitation -> Repo.delete(invitation)
      %Invitation{} -> {:error, :already_accepted}
    end
  end

  @doc """
  Emails an invitation to its recipient. `accept_url` is the full accept link
  (built by the web layer from the raw token, which is never stored).
  """
  def deliver_invitation(%Invitation{} = invitation, workspace, inviter, accept_url) do
    AccountNotifier.deliver_invitation_instructions(invitation, workspace, inviter, accept_url)
  end

  @doc """
  Accepts an invitation by raw token for the given account, creating the
  membership. The accepting account's email must match the invitation.
  """
  def accept_invitation(%Account{} = account, raw_token) do
    token_hash = Invitation.hash_token(raw_token)

    # The token itself is the authorization here, so this lookup is
    # legitimately cross-workspace.
    with %Invitation{} = invitation <-
           Repo.get_by(Invitation, [token_hash: token_hash], skip_workspace_guard: true) ||
             {:error, :not_found},
         :ok <- check_invitation_pending(invitation),
         :ok <- check_invitation_email(invitation, account) do
      Repo.transact(fn ->
        with {:ok, membership} <-
               %Membership{}
               |> Membership.changeset(%{
                 workspace_id: invitation.workspace_id,
                 account_id: account.id,
                 role: invitation.role,
                 invited_by_id: invitation.invited_by_id
               })
               |> Repo.insert(),
             {:ok, _} <-
               invitation
               |> Ecto.Changeset.change(accepted_at: DateTime.utc_now(:second))
               |> Repo.update() do
          {:ok, membership}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_invitation_pending(%Invitation{accepted_at: %DateTime{}}),
    do: {:error, :already_accepted}

  defp check_invitation_pending(%Invitation{} = invitation) do
    if Invitation.expired?(invitation), do: {:error, :expired}, else: :ok
  end

  defp check_invitation_email(%Invitation{email: email}, %Account{} = account) do
    if String.downcase(account.email) == email, do: :ok, else: {:error, :email_mismatch}
  end
end
