defmodule Flux.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Flux.Repo

  alias Flux.Accounts.{Account, AccountNotifier, AccountToken}

  @doc "The account's active sessions, newest first (for the security page)."
  def list_session_tokens(%Account{id: account_id}) do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from(t in AccountToken,
        where: t.account_id == ^account_id and t.context == "session",
        order_by: [desc: t.inserted_at]
      )
    )
  end

  @doc "Revokes one session by token row id — that device is logged out."
  def revoke_session_token(%Account{id: account_id}, token_id) do
    import Ecto.Query, only: [from: 2]

    Repo.delete_all(
      from(t in AccountToken,
        where: t.id == ^token_id and t.account_id == ^account_id and t.context == "session"
      )
    )

    :ok
  end

  @doc "Saves which notification kinds this account wants emailed."
  def set_notification_email_kinds(%Account{} = account, kinds) when is_list(kinds) do
    kinds = Enum.filter(kinds, &(&1 in Flux.Notifications.kinds()))

    account
    |> Ecto.Changeset.change(notification_email_kinds: kinds)
    |> Repo.update()
  end

  @doc "Members of a workspace who opted into email for this kind."
  def emails_subscribed_to(workspace_id, kind) do
    for account <- accounts_subscribed_to(workspace_id, kind), do: account.email
  end

  @doc "Accounts (not just emails) opted into a kind — quiet hours need the full row."
  def accounts_subscribed_to(workspace_id, kind) do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from(m in Flux.Accounts.Membership,
        join: a in Account,
        on: a.id == m.account_id,
        where: m.workspace_id == ^workspace_id and ^kind in a.notification_email_kinds,
        select: a
      )
    )
  end

  @doc "Sets (or with nils, clears) the account's UTC quiet hours for emails."
  def set_quiet_hours(%Account{} = account, start_hour, end_hour)
      when (is_nil(start_hour) and is_nil(end_hour)) or
             (start_hour in 0..23 and end_hour in 0..23) do
    account
    |> Ecto.Changeset.change(quiet_hours_start: start_hour, quiet_hours_end: end_hour)
    |> Repo.update()
  end

  @doc "Whether `hour` (UTC) falls inside the account's quiet window (wraps midnight)."
  def in_quiet_hours?(%Account{quiet_hours_start: start_hour, quiet_hours_end: end_hour}, hour)
      when is_integer(start_hour) and is_integer(end_hour) do
    if start_hour <= end_hour do
      hour >= start_hour and hour < end_hour
    else
      hour >= start_hour or hour < end_hour
    end
  end

  def in_quiet_hours?(_account, _hour), do: false

  ## Favorites (per-account stars on fluxes and apps)

  def toggle_favorite(%Account{} = account, item_type, item_id)
      when item_type in ["flux", "app"] do
    import Ecto.Query, only: [from: 2]

    case Repo.one(
           from(f in Flux.Accounts.Favorite,
             where:
               f.account_id == ^account.id and f.item_type == ^item_type and
                 f.item_id == ^item_id
           )
         ) do
      nil ->
        Repo.insert!(%Flux.Accounts.Favorite{
          account_id: account.id,
          item_type: item_type,
          item_id: item_id
        })

        {:ok, :starred}

      favorite ->
        Repo.delete!(favorite)
        {:ok, :unstarred}
    end
  end

  @doc "MapSet of the account's starred ids for one item type."
  def favorite_ids(%Account{} = account, item_type) do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from(f in Flux.Accounts.Favorite,
        where: f.account_id == ^account.id and f.item_type == ^item_type,
        select: f.item_id
      )
    )
    |> MapSet.new()
  end

  @doc "Logs the account out everywhere by deleting every session token."
  def revoke_all_session_tokens(%Account{id: account_id}) do
    import Ecto.Query, only: [from: 2]

    Repo.delete_all(
      from(t in AccountToken, where: t.account_id == ^account_id and t.context == "session")
    )

    :ok
  end

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

  @doc """
  Fetches or provisions the account for an SSO-verified email. The
  identity provider owns email verification, so new accounts arrive
  confirmed.
  """
  def get_or_register_sso_account(email) when is_binary(email) do
    case get_account_by_email(email) do
      %Account{} = account ->
        {:ok, account}

      nil ->
        %Account{}
        |> Account.email_changeset(%{email: email})
        |> Ecto.Changeset.put_change(
          :confirmed_at,
          NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
        )
        |> Repo.insert()
    end
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

  ## TOTP two-factor authentication

  @doc "Whether login requires a TOTP code for this account."
  def totp_enabled?(%Account{totp_confirmed_at: confirmed_at}), do: confirmed_at != nil
  def totp_enabled?(_account), do: false

  @doc """
  Starts TOTP enrollment: stores a fresh secret (unconfirmed — login is
  unaffected until `confirm_totp/2`) and returns `{account, otpauth_uri}`
  for the QR code / manual entry.
  """
  def init_totp(%Account{} = account) do
    secret = NimbleTOTP.secret()

    account =
      account
      |> Ecto.Changeset.change(totp_secret: secret, totp_confirmed_at: nil)
      |> Repo.update!()

    uri =
      NimbleTOTP.otpauth_uri("FluxCapacitor:#{account.email}", secret, issuer: "FluxCapacitor")

    {account, uri}
  end

  @doc """
  Confirms enrollment with a code from the authenticator app. On success
  2FA is on and the plaintext recovery codes are returned — this is the
  only time they exist unhashed.
  """
  def confirm_totp(%Account{totp_secret: secret} = account, code) when is_binary(secret) do
    if NimbleTOTP.valid?(secret, to_string(code)) do
      recovery_codes =
        for _n <- 1..8 do
          Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)
        end

      account =
        account
        |> Ecto.Changeset.change(
          totp_confirmed_at: DateTime.utc_now(:second),
          totp_recovery_codes: Enum.map(recovery_codes, &hash_recovery_code/1)
        )
        |> Repo.update!()

      {:ok, account, recovery_codes}
    else
      {:error, :invalid_code}
    end
  end

  def confirm_totp(_account, _code), do: {:error, :not_enrolled}

  @doc "Turns 2FA off and discards the secret and recovery codes."
  def disable_totp(%Account{} = account) do
    account
    |> Ecto.Changeset.change(
      totp_secret: nil,
      totp_confirmed_at: nil,
      totp_recovery_codes: []
    )
    |> Repo.update!()
  end

  @doc """
  Verifies a login challenge: a current TOTP code, or one of the
  recovery codes (which is consumed — each works exactly once).
  """
  def verify_totp(%Account{totp_secret: secret} = account, code) when is_binary(secret) do
    code = code |> to_string() |> String.trim() |> String.downcase()

    cond do
      NimbleTOTP.valid?(secret, code) ->
        {:ok, account}

      hash_recovery_code(code) in account.totp_recovery_codes ->
        account
        |> Ecto.Changeset.change(
          totp_recovery_codes: List.delete(account.totp_recovery_codes, hash_recovery_code(code))
        )
        |> Repo.update!()

        {:ok, account}

      true ->
        {:error, :invalid_code}
    end
  end

  def verify_totp(_account, _code), do: {:error, :not_enrolled}

  defp hash_recovery_code(code) do
    :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)
  end

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
  def generate_account_session_token(account, device_info \\ %{}) do
    {token, account_token} = AccountToken.build_session_token(account)

    account_token = %{
      account_token
      | ip: device_info[:ip],
        user_agent: device_info[:user_agent] && String.slice(device_info[:user_agent], 0, 250)
    }

    maybe_alert_new_device(account, account_token.ip, account_token.user_agent)

    Repo.insert!(account_token)
    token
  end

  # A sign-in from an ip + browser pair no earlier session used gets an
  # alert email. First-ever sessions stay silent — everything is new then.
  defp maybe_alert_new_device(account, ip, user_agent) when is_binary(ip) do
    sessions =
      Repo.all(
        from(t in AccountToken,
          where: t.account_id == ^account.id and t.context == "session",
          select: {t.ip, t.user_agent}
        )
      )

    if sessions != [] and {ip, user_agent} not in sessions do
      AccountNotifier.deliver_new_device_alert(account, ip, user_agent)
    end

    :ok
  end

  defp maybe_alert_new_device(_account, _ip, _user_agent), do: :ok

  @doc """
  Gets the account with the given signed token.

  If the token is valid `{account, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_account_by_session_token(token) do
    {:ok, query} = AccountToken.verify_session_token_query(token)
    result = Repo.one(query)

    if result, do: touch_session_token(token)
    result
  end

  # Keeps the idle-timeout clock honest without a write per request:
  # last_used_at only advances when it is more than five minutes stale.
  defp touch_session_token(token) do
    if AccountToken.idle_timeout_minutes() do
      from(t in AccountToken.by_token_and_context_query(token, "session"),
        where: coalesce(t.last_used_at, t.inserted_at) < ago(5, "minute")
      )
      |> Repo.update_all(set: [last_used_at: DateTime.utc_now(:second)])
    end

    :ok
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

  ## SCIM provisioning

  @doc """
  Mints (replacing any prior) the workspace's SCIM bearer token and
  returns the raw once — only its hash is stored.
  """
  def enable_scim(%Scope{} = scope) do
    with :ok <- Flux.Features.authorize(scope, :scim),
         :ok <- Flux.RBAC.authorize(scope, :workspace_member_manage),
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      raw = "scim_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      custom_config =
        Map.put(workspace.custom_config || %{}, "scim_token_hash", scim_hash(raw))

      with {:ok, _updated} <-
             workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update() do
        Flux.Audit.record(scope, "workspace.scim_enable",
          resource_type: "workspace",
          resource_id: workspace.id
        )

        {:ok, raw}
      end
    end
  end

  def disable_scim(%Scope{} = scope) do
    with :ok <- Flux.RBAC.authorize(scope, :workspace_member_manage),
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)),
         {:ok, _updated} <-
           workspace
           |> Ecto.Changeset.change(
             custom_config: Map.delete(workspace.custom_config || %{}, "scim_token_hash")
           )
           |> Repo.update() do
      Flux.Audit.record(scope, "workspace.scim_disable",
        resource_type: "workspace",
        resource_id: workspace.id
      )

      :ok
    end
  end

  def scim_enabled?(%Scope{} = scope) do
    match?(
      %{custom_config: %{"scim_token_hash" => _hash}},
      Repo.get(Workspace, Scope.workspace_id(scope))
    )
  end

  @doc "Resolves a SCIM bearer token to its workspace."
  def workspace_by_scim_token("scim_" <> _rest = raw) do
    hash = scim_hash(raw)

    from(w in Workspace, where: fragment("? ->> 'scim_token_hash' = ?", w.custom_config, ^hash))
    |> Repo.one()
    |> case do
      nil -> {:error, :unauthorized}
      workspace -> {:ok, workspace}
    end
  end

  def workspace_by_scim_token(_other), do: {:error, :unauthorized}

  defp scim_hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  # System-level member operations for the SCIM API — the workspace-bound
  # bearer token is the authorization, so no scope RBAC applies here.

  def scim_list_members(workspace_id) do
    from(m in Membership,
      where: m.workspace_id == ^workspace_id,
      join: a in assoc(m, :account),
      preload: [account: a],
      order_by: a.email
    )
    |> Repo.all()
  end

  def scim_find_member(workspace_id, account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, _uuid} ->
        from(m in Membership,
          where: m.workspace_id == ^workspace_id and m.account_id == ^account_id,
          join: a in assoc(m, :account),
          preload: [account: a]
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc "Provisions (or 409s on) a member for the email; accounts arrive confirmed."
  def scim_provision(%Workspace{} = workspace, email) when is_binary(email) do
    with {:ok, account} <- get_or_register_sso_account(String.downcase(email)) do
      case scim_find_member(workspace.id, account.id) do
        nil ->
          {:ok, membership} =
            %Membership{}
            |> Membership.changeset(%{
              workspace_id: workspace.id,
              account_id: account.id,
              role: :normal
            })
            |> Repo.insert()

          Flux.Audit.record(scim_scope(workspace), "member.scim_provision",
            resource_type: "membership",
            resource_id: membership.id,
            metadata: %{"email" => account.email}
          )

          {:ok, %{membership | account: account}}

        _member ->
          {:error, :conflict}
      end
    end
  end

  @doc "Removes the member (never the global account). Owners are refused."
  def scim_deprovision(%Workspace{} = workspace, account_id) do
    case scim_find_member(workspace.id, account_id) do
      nil ->
        {:error, :not_found}

      %Membership{role: :owner} ->
        {:error, :owner}

      %Membership{} = membership ->
        {:ok, _deleted} = Repo.delete(membership)

        Flux.Audit.record(scim_scope(workspace), "member.scim_deprovision",
          resource_type: "membership",
          resource_id: membership.id,
          metadata: %{"account_id" => account_id}
        )

        :ok
    end
  end

  @doc """
  Sets a member's role from IdP group membership (SCIM Groups PATCH).
  The workspace token is the authorization — no account scope here, same
  trust model as `scim_provision/2`. Owners are never touched.
  """
  def scim_set_member_role(%Workspace{} = workspace, account_id, role)
      when role in [:admin, :editor, :normal, :dataset_operator] do
    case scim_find_member(workspace.id, account_id) do
      nil ->
        {:error, :not_found}

      %Membership{role: :owner} ->
        {:error, :owner}

      %Membership{role: ^role} = membership ->
        {:ok, membership}

      %Membership{} = membership ->
        {:ok, updated} = membership |> Ecto.Changeset.change(role: role) |> Repo.update()

        Flux.Audit.record(scim_scope(workspace), "member.scim_role_change",
          resource_type: "membership",
          resource_id: membership.id,
          metadata: %{"account_id" => account_id, "role" => to_string(role)}
        )

        {:ok, %{updated | account: membership.account}}
    end
  end

  defp scim_scope(workspace), do: %Scope{account: nil, membership: nil, workspace: workspace}

  @doc "Sets the run/message retention window in days (nil = keep forever)."
  def set_retention_days(%Scope{} = scope, days) when is_nil(days) or days in 1..3650 do
    with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      custom_config =
        if days do
          Map.put(workspace.custom_config || %{}, "retention_days", days)
        else
          Map.delete(workspace.custom_config || %{}, "retention_days")
        end

      with {:ok, updated} <-
             workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update() do
        Flux.Audit.record(scope, "workspace.retention_set",
          resource_type: "workspace",
          resource_id: workspace.id,
          metadata: %{"days" => days}
        )

        {:ok, updated}
      end
    end
  end

  @doc """
  Sets (or with blank, clears) the workspace system prompt — an
  org-wide prefix baked into every chat app's model calls (compliance
  boilerplate, tone rules) so apps stop repeating it by hand.
  """
  def set_workspace_system_prompt(%Scope{} = scope, prompt) do
    with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      trimmed = String.trim(to_string(prompt || ""))

      custom_config =
        if trimmed == "" do
          Map.delete(workspace.custom_config || %{}, "system_prompt")
        else
          Map.put(
            workspace.custom_config || %{},
            "system_prompt",
            String.slice(trimmed, 0, 4_000)
          )
        end

      workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update()
    end
  end

  def workspace_system_prompt(%Scope{} = scope),
    do: system_prompt_for_workspace(Scope.workspace_id(scope))

  @doc "Worker-safe read of the org-wide system prompt (nil when unset)."
  def system_prompt_for_workspace(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %{custom_config: %{"system_prompt" => prompt}} when is_binary(prompt) and prompt != "" ->
        prompt

      _none ->
        nil
    end
  end

  def retention_days(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"retention_days" => days}} -> days
      _none -> nil
    end
  end

  @doc """
  Separate window for the audit trail (nil = keep forever, the
  default). Pruning audit is an explicit data-minimization choice, so
  it never rides along with the operational `retention_days`.
  """
  def set_audit_retention_days(%Scope{} = scope, days) when is_nil(days) or days in 30..3650 do
    update_custom_config(scope, "audit_retention_days", days)
  end

  def audit_retention_days(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"audit_retention_days" => days}} -> days
      _forever -> nil
    end
  end

  @doc """
  Sets (or with nil/blank, clears) the scheduled-export cron: the sweep
  writes the workspace export archive to storage on this schedule.
  """
  def set_export_schedule(%Scope{} = scope, cron) do
    cron = String.trim(to_string(cron || ""))

    with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
         :ok <- validate_export_cron(cron),
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      custom_config =
        if cron == "" do
          Map.delete(workspace.custom_config || %{}, "export_schedule")
        else
          Map.put(workspace.custom_config || %{}, "export_schedule", cron)
        end

      workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update()
    end
  end

  defp validate_export_cron(""), do: :ok

  defp validate_export_cron(cron) do
    case Oban.Cron.Expression.parse(cron) do
      {:ok, _expression} -> :ok
      {:error, _reason} -> {:error, :invalid_cron}
    end
  end

  def export_schedule(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"export_schedule" => cron}} -> cron
      _none -> nil
    end
  end

  @doc "Whether the account may open the instance admin panel (FLUX_ADMIN_EMAILS)."
  def instance_admin?(%{email: email}) do
    email in Application.get_env(:flux, :instance_admins, [])
  end

  def instance_admin?(_account), do: false

  @doc """
  The operator's view: every workspace with plan, member count, 30-day
  run/token totals, and storage. Instance-admin only — callers gate with
  `instance_admin?/1`.
  """
  def instance_overview do
    since = DateTime.add(DateTime.utc_now(:second), -30, :day)

    members =
      Membership
      |> group_by([m], m.workspace_id)
      |> select([m], {m.workspace_id, count(m.id)})
      |> Repo.all()
      |> Map.new()

    runs =
      Flux.Workflows.WorkflowRun
      |> where([r], r.inserted_at >= ^since)
      |> select([r], %{workspace_id: r.workspace_id, usage: r.usage})
      |> Repo.all(skip_workspace_guard: true)
      |> Enum.group_by(& &1.workspace_id)

    storage =
      Flux.Chat.UploadedFile
      |> group_by([f], f.workspace_id)
      |> select([f], {f.workspace_id, fragment("coalesce(sum(?), 0)::bigint", f.size)})
      |> Repo.all(skip_workspace_guard: true)
      |> Map.new()

    for workspace <- Repo.all(order_by(Workspace, asc: :inserted_at)) do
      workspace_runs = Map.get(runs, workspace.id, [])

      %{
        workspace: workspace,
        plan: Flux.Features.plan_for_workspace(workspace.id),
        members: Map.get(members, workspace.id, 0),
        runs_30d: length(workspace_runs),
        tokens_30d:
          Enum.sum(
            for run <- workspace_runs,
                do: (run.usage["input_tokens"] || 0) + (run.usage["output_tokens"] || 0)
          ),
        storage_bytes: Map.get(storage, workspace.id, 0)
      }
    end
  end

  @doc "Sets the LLM response-cache TTL in minutes (0/nil = off)."
  def set_llm_cache_minutes(%Scope{} = scope, minutes)
      when is_nil(minutes) or minutes in 0..10_080 do
    update_custom_config(scope, "llm_cache_minutes", (minutes in [nil, 0] && nil) || minutes)
  end

  def llm_cache_minutes(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"llm_cache_minutes" => minutes}} -> minutes
      _off -> 0
    end
  end

  @doc """
  Workspace-wide default model params: applied wherever an app or LLM
  node doesn't set its own. Only temperature and max_tokens — the two
  worth defaulting globally. Both blank turns the defaults off.
  """
  def set_default_model_params(%Scope{} = scope, temperature, max_tokens) do
    params =
      %{}
      |> then(fn params ->
        case parse_float_in(temperature, 0.0, 2.0) do
          nil -> params
          value -> Map.put(params, "temperature", value)
        end
      end)
      |> then(fn params ->
        case parse_int_in(max_tokens, 1, 1_000_000) do
          nil -> params
          value -> Map.put(params, "max_tokens", value)
        end
      end)

    update_custom_config(scope, "default_params", (params == %{} && nil) || params)
  end

  @doc "The configured defaults as an atom-keyed map (empty when off)."
  def default_model_params(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %{custom_config: %{"default_params" => %{} = params}} ->
        for {key, value} <- params,
            key in ["temperature", "max_tokens"],
            into: %{},
            do: {String.to_existing_atom(key), value}

      _off ->
        %{}
    end
  end

  defp parse_float_in(value, min, max) do
    case Float.parse(to_string(value || "")) do
      {float, ""} when float >= min and float <= max -> float
      _blank_or_invalid -> nil
    end
  end

  defp parse_int_in(value, min, max) do
    case Integer.parse(to_string(value || "")) do
      {int, ""} when int >= min and int <= max -> int
      _blank_or_invalid -> nil
    end
  end

  @doc """
  Sets the workspace default console locale (a Gettext short code such
  as "de"). It fills in when a member never picked a locale and their
  browser negotiation misses; nil returns to pure browser negotiation.
  """
  def set_workspace_locale(%Scope{} = scope, locale)
      when is_nil(locale) or (is_binary(locale) and byte_size(locale) <= 10) do
    update_custom_config(scope, "locale", locale)
  end

  def workspace_locale(%Scope{} = scope) do
    case scope.workspace do
      %{custom_config: %{"locale" => locale}} when is_binary(locale) -> locale
      _unset -> nil
    end
  end

  @doc ~S(Digest cadence: "weekly" default, "daily", or "off".)
  def set_digest_frequency(%Scope{} = scope, frequency)
      when frequency in ["weekly", "daily", "off"] do
    update_custom_config(scope, "digest_frequency", (frequency == "weekly" && nil) || frequency)
  end

  def digest_frequency(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"digest_frequency" => frequency}} -> frequency
      _default -> "weekly"
    end
  end

  @doc "White-label sidebar logo (blank restores the wordmark)."
  def set_console_logo(%Scope{} = scope, url) do
    trimmed = String.trim(to_string(url))
    update_custom_config(scope, "console_logo_url", (trimmed == "" && nil) || trimmed)
  end

  def console_logo(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"console_logo_url" => url}} -> url
      _none -> nil
    end
  end

  @doc "Sets the max simultaneous interactive runs (nil = unlimited)."
  def set_max_concurrent_runs(%Scope{} = scope, cap)
      when is_nil(cap) or (is_integer(cap) and cap in 1..1000) do
    update_custom_config(scope, "max_concurrent_runs", cap)
  end

  def max_concurrent_runs(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"max_concurrent_runs" => cap}} -> cap
      _unlimited -> nil
    end
  end

  @doc "Sets the monthly token budget (nil = unlimited)."
  def set_token_budget(%Scope{} = scope, budget)
      when is_nil(budget) or (is_integer(budget) and budget > 0) do
    update_custom_config(scope, "monthly_token_budget", budget)
  end

  def token_budget(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"monthly_token_budget" => budget}} -> budget
      _unlimited -> nil
    end
  end

  @doc """
  Configures OIDC claim→role mapping for this workspace: `claim` names
  the id-token claim to read (e.g. "groups"), `mapping` is
  %{"claim value" => "role"}. nil/empty clears it.
  """
  def set_oidc_role_mapping(%Scope{} = scope, claim, mapping) do
    claim = ((claim || "") |> String.trim() != "" && String.trim(claim)) || nil
    mapping = (is_map(mapping) and map_size(mapping) > 0 && mapping) || nil

    with {:ok, _workspace} <- update_custom_config(scope, "oidc_role_claim", claim) do
      update_custom_config(scope, "oidc_role_map", (claim && mapping) || nil)
    end
  end

  def oidc_role_mapping(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"oidc_role_claim" => claim, "oidc_role_map" => mapping}}
      when is_binary(claim) and is_map(mapping) ->
        {claim, mapping}

      _unset ->
        {nil, %{}}
    end
  end

  @doc """
  Applies OIDC claim→role mappings after an SSO login: every workspace
  the account belongs to that configured a mapping gets the member's
  role set from the id-token claims. Owners never move; workspaces
  without a mapping are untouched; unmatched claim values leave the
  role alone (removal is a human decision, not a login side effect).
  """
  def apply_oidc_roles(%Account{} = account, claims) when is_map(claims) do
    memberships =
      Repo.all(
        from(m in Membership,
          where: m.account_id == ^account.id and m.role != :owner,
          join: w in Workspace,
          on: w.id == m.workspace_id,
          select: {m, w.custom_config}
        )
      )

    for {membership, %{"oidc_role_claim" => claim, "oidc_role_map" => mapping}} <- memberships,
        is_binary(claim) and is_map(mapping) do
      values = claims[claim] |> List.wrap() |> Enum.map(&to_string/1)

      role =
        Enum.find_value(values, fn value ->
          case mapping[value] do
            mapped when mapped in ~w(admin editor normal dataset_operator) -> mapped
            _unmapped -> nil
          end
        end)

      if role && role != to_string(membership.role) do
        membership
        |> Ecto.Changeset.change(role: String.to_existing_atom(role))
        |> Repo.update()

        Flux.Audit.record(
          %Scope{
            account: nil,
            membership: nil,
            workspace: %Workspace{id: membership.workspace_id}
          },
          "member.oidc_role_change",
          resource_type: "membership",
          resource_id: membership.id,
          metadata: %{"account_id" => account.id, "role" => role}
        )
      end
    end

    :ok
  end

  defp update_custom_config(scope, key, value) do
    with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      custom_config =
        if value == nil do
          Map.delete(workspace.custom_config || %{}, key)
        else
          Map.put(workspace.custom_config || %{}, key, value)
        end

      workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update()
    end
  end

  @doc "Sets (or with nil/blank, clears) the failed-run alert webhook URL."
  def set_alert_url(%Scope{} = scope, url) do
    url = url && String.trim(url)

    with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
         :ok <- (url in [nil, ""] && :ok) || Flux.SSRF.verify_url(url),
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      custom_config =
        if url in [nil, ""] do
          Map.delete(workspace.custom_config || %{}, "alert_url")
        else
          # A signing secret is minted with the first URL so receivers can
          # verify the x-flux-signature header on every alert.
          (workspace.custom_config || %{})
          |> Map.put("alert_url", url)
          |> Map.put_new_lazy("alert_secret", fn ->
            "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
          end)
        end

      with {:ok, updated} <-
             workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update() do
        Flux.Audit.record(scope, "workspace.alert_url_set",
          resource_type: "workspace",
          resource_id: workspace.id
        )

        {:ok, updated}
      end
    end
  end

  def alert_url(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"alert_url" => url}} -> url
      _none -> nil
    end
  end

  @doc "The HMAC secret alert deliveries are signed with (nil until a URL is set)."
  def alert_secret(%Scope{} = scope) do
    case Repo.get(Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"alert_secret" => secret}} -> secret
      _none -> nil
    end
  end

  @doc "Renames the current workspace (customization_manage)."
  def rename_workspace(%Scope{} = scope, name) when is_binary(name) do
    name = String.trim(name)

    with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
         true <- name != "" || {:error, :invalid_name},
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)),
         {:ok, renamed} <-
           workspace |> Ecto.Changeset.change(name: name) |> Repo.update() do
      Flux.Audit.record(scope, "workspace.rename",
        resource_type: "workspace",
        resource_id: workspace.id,
        metadata: %{"from" => workspace.name, "to" => name}
      )

      {:ok, renamed}
    end
  end

  @doc """
  Deletes the current workspace and everything in it (owner only; FK
  cascades remove apps, fluxes, datasets, runs, members).
  """
  def delete_workspace(%Scope{} = scope) do
    with true <- Scope.role(scope) == :owner || {:error, :unauthorized},
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      Repo.delete(workspace)
    end
  end

  @doc """
  Archives the workspace (owner only): it leaves the switcher and stops
  resolving as anyone's current workspace, but nothing is deleted — the
  gentle alternative to the danger zone. Instance admins restore.
  """
  def archive_workspace(%Scope{} = scope) do
    with true <- Scope.role(scope) == :owner || {:error, :unauthorized},
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      workspace |> Ecto.Changeset.change(status: "archived") |> Repo.update()
    end
  end

  @doc "Instance-admin restore of an archived workspace."
  def restore_workspace(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{status: "archived"} = workspace ->
        workspace |> Ecto.Changeset.change(status: "normal") |> Repo.update()

      %Workspace{} = workspace ->
        {:ok, workspace}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Archived workspaces, for the admin panel's restore list."
  def archived_workspaces do
    Repo.all(from(w in Workspace, where: w.status == "archived", order_by: [desc: w.updated_at]))
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
      not Flux.RBAC.can?(scope, :workspace_member_manage) ->
        {:error, :unauthorized}

      membership.workspace_id != Scope.workspace_id(scope) ->
        {:error, :not_found}

      membership.role == :owner ->
        {:error, :cannot_change_owner_role}

      true ->
        with {:ok, updated} <-
               membership |> Ecto.Changeset.change(role: new_role) |> Repo.update() do
          Flux.Audit.record(scope, "member.role_change",
            resource_type: "membership",
            resource_id: membership.id,
            metadata: %{"from" => to_string(membership.role), "to" => to_string(new_role)}
          )

          {:ok, updated}
        end
    end
  end

  def update_member_role(%Scope{}, %Membership{}, _new_role), do: {:error, :invalid_role}

  @doc "Removes a member from the workspace. The owner cannot be removed."
  def remove_member(%Scope{} = scope, %Membership{} = membership) do
    cond do
      not Flux.RBAC.can?(scope, :workspace_member_manage) ->
        {:error, :unauthorized}

      membership.workspace_id != Scope.workspace_id(scope) ->
        {:error, :not_found}

      membership.role == :owner ->
        {:error, :cannot_remove_owner}

      membership.account_id == Scope.account_id(scope) ->
        {:error, :cannot_remove_self}

      true ->
        with {:ok, deleted} <- Repo.delete(membership) do
          Flux.Audit.record(scope, "member.remove",
            resource_type: "membership",
            resource_id: membership.id,
            metadata: %{"account_id" => membership.account_id}
          )

          {:ok, deleted}
        end
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
