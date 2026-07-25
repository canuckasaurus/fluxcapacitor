defmodule Dify.Accounts.Invitation do
  @moduledoc """
  A pending email invitation into a workspace. The raw token is emailed to the
  invitee; only its SHA-256 hash is stored. Accepting creates a membership and
  stamps `accepted_at`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @rand_size 32
  @default_validity_days 7

  # Owners are created with the workspace, never by invitation.
  @invitable_roles ~w(admin editor normal dataset_operator)a

  schema "invitations" do
    belongs_to :workspace, Dify.Accounts.Workspace
    belongs_to :invited_by, Dify.Accounts.Account

    field :email, :string
    field :role, Ecto.Enum, values: @invitable_roles
    field :token_hash, :binary, redact: true
    field :accepted_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def invitable_roles, do: @invitable_roles

  @doc """
  Builds a changeset for a new invitation and returns `{raw_token, changeset}`.
  The raw token is URL-safe base64; only its hash is persisted.
  """
  def build(workspace_id, invited_by_id, attrs) do
    raw_token = :crypto.strong_rand_bytes(@rand_size) |> Base.url_encode64(padding: false)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:email, :role])
      |> validate_required([:email, :role])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)
      |> update_change(:email, &String.downcase/1)
      |> put_change(:workspace_id, workspace_id)
      |> put_change(:invited_by_id, invited_by_id)
      |> put_change(:token_hash, hash_token(raw_token))
      |> put_change(
        :expires_at,
        DateTime.utc_now(:second) |> DateTime.add(@default_validity_days, :day)
      )
      |> unique_constraint([:workspace_id, :email], name: :invitations_pending_unique_index)

    {raw_token, changeset}
  end

  def hash_token(raw_token), do: :crypto.hash(:sha256, raw_token)

  def expired?(%__MODULE__{expires_at: expires_at}),
    do: DateTime.compare(DateTime.utc_now(), expires_at) == :gt
end
