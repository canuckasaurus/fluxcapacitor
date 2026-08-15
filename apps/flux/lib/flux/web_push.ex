defmodule Flux.WebPush do
  @moduledoc """
  Native Web Push (RFC 8291 aes128gcm + RFC 8292 VAPID) on top of
  `:crypto` — no external push service SDK. The instance VAPID keypair
  is generated lazily and kept in `Flux.InstanceSettings`; browsers
  subscribe against the public key and each subscription is stored per
  account. Delivery happens through Oban (`Flux.WebPush.Worker`) so a
  slow or dead push endpoint never blocks the caller; gone endpoints
  (404/410) drop their subscription.
  """

  import Ecto.Query

  alias Flux.InstanceSettings
  alias Flux.Repo

  @push_kinds ~w(handoff run_failed)

  defmodule Subscription do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "push_subscriptions" do
      belongs_to :account, Flux.Accounts.Account

      field :endpoint, :string
      field :p256dh, :string
      field :auth, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end
  end

  @doc "Notification kinds that fan out to browser push."
  def push_kinds, do: @push_kinds

  ## Subscriptions

  def subscribe(%Flux.Accounts.Account{} = account, %{
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => p256dh, "auth" => auth}
      })
      when is_binary(endpoint) and is_binary(p256dh) and is_binary(auth) do
    %Subscription{account_id: account.id, endpoint: endpoint, p256dh: p256dh, auth: auth}
    |> Repo.insert(
      on_conflict: {:replace, [:p256dh, :auth]},
      conflict_target: [:account_id, :endpoint]
    )
  end

  def subscribe(_account, _params), do: {:error, :invalid_subscription}

  def unsubscribe(%Flux.Accounts.Account{} = account, endpoint) when is_binary(endpoint) do
    from(s in Subscription, where: s.account_id == ^account.id and s.endpoint == ^endpoint)
    |> Repo.delete_all()

    :ok
  end

  def subscribed?(%Flux.Accounts.Account{} = account) do
    Repo.exists?(from(s in Subscription, where: s.account_id == ^account.id))
  end

  def subscriptions_for(account_ids) when is_list(account_ids) do
    Repo.all(from(s in Subscription, where: s.account_id in ^account_ids))
  end

  @doc """
  Enqueues one delivery job per push subscription held by the given
  accounts. Called from `Flux.Notifications.notify/4` for push-worthy
  kinds; safe to call with an empty list.
  """
  def fan_out(account_ids, title, path) do
    for subscription <- subscriptions_for(account_ids) do
      %{subscription_id: subscription.id, title: title, path: path}
      |> Flux.WebPush.Worker.new()
      |> Oban.insert()
    end

    :ok
  end

  ## VAPID keys

  @doc "The instance VAPID public key (base64url), for `pushManager.subscribe`."
  def vapid_public_key do
    {public, _private} = vapid_keys()
    Base.url_encode64(public, padding: false)
  end

  defp vapid_keys do
    case {InstanceSettings.get("vapid_public_key"), InstanceSettings.get("vapid_private_key")} do
      {public, private} when is_binary(public) and is_binary(private) ->
        {Base.url_decode64!(public, padding: false), Base.url_decode64!(private, padding: false)}

      _missing ->
        {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
        InstanceSettings.put("vapid_public_key", Base.url_encode64(public, padding: false))
        InstanceSettings.put("vapid_private_key", Base.url_encode64(private, padding: false))
        {public, private}
    end
  end

  ## Delivery

  @doc """
  Encrypts and POSTs one payload to one subscription. Returns `:ok`,
  `{:error, :gone}` when the endpoint says the subscription is dead
  (the caller should delete it), or `{:error, reason}`.
  """
  def push(%Subscription{} = subscription, payload) when is_map(payload) do
    body = encrypt(Jason.encode!(payload), subscription.p256dh, subscription.auth)

    headers = [
      {"authorization", vapid_authorization(subscription.endpoint)},
      {"content-encoding", "aes128gcm"},
      {"ttl", "86400"},
      {"urgency", "normal"}
    ]

    options =
      [url: subscription.endpoint, headers: headers, body: body, retry: false] ++
        Application.get_env(:flux, :webpush_req_options, [])

    case Req.post(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} when status in [404, 410] -> {:error, :gone}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## RFC 8291 payload encryption (aes128gcm)

  defp encrypt(message, p256dh_b64, auth_b64) do
    client_public = Base.url_decode64!(p256dh_b64, padding: false)
    auth_secret = Base.url_decode64!(auth_b64, padding: false)

    salt = :crypto.strong_rand_bytes(16)
    {server_public, server_private} = :crypto.generate_key(:ecdh, :prime256v1)
    shared_secret = :crypto.compute_key(:ecdh, client_public, server_private, :prime256v1)

    key_info = "WebPush: info" <> <<0>> <> client_public <> server_public
    ikm = hkdf(auth_secret, shared_secret, key_info, 32)
    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>>, 12)

    # A single record: the 0x02 delimiter marks it as the last one.
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, message <> <<2>>, <<>>, true)

    header =
      salt <> <<4096::unsigned-32>> <> <<byte_size(server_public)::unsigned-8>> <> server_public

    header <> ciphertext <> tag
  end

  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    :hmac
    |> :crypto.mac(:sha256, prk, info <> <<1>>)
    |> binary_part(0, length)
  end

  ## RFC 8292 VAPID (ES256 JWT)

  defp vapid_authorization(endpoint) do
    {public, private} = vapid_keys()
    %URI{scheme: scheme, host: host} = URI.parse(endpoint)

    claims = %{
      "aud" => "#{scheme}://#{host}",
      "exp" => System.system_time(:second) + 12 * 3600,
      "sub" => "mailto:" <> Application.get_env(:flux, :mail_from, "contact@example.com")
    }

    header = %{"typ" => "JWT", "alg" => "ES256"} |> Jason.encode!() |> b64()
    body = claims |> Jason.encode!() |> b64()
    signing_input = header <> "." <> body

    der = :crypto.sign(:ecdsa, :sha256, signing_input, [private, :prime256v1])
    jwt = signing_input <> "." <> b64(der_to_raw(der))

    "vapid t=#{jwt}, k=#{Base.url_encode64(public, padding: false)}"
  end

  # JOSE wants the raw 64-byte r||s form, :crypto emits DER.
  defp der_to_raw(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::unsigned-256, s::unsigned-256>>
  end

  defp b64(binary), do: Base.url_encode64(binary, padding: false)
end

defmodule Flux.WebPush.Worker do
  @moduledoc "Delivers one browser push; drops subscriptions the endpoint reports gone."
  use Oban.Worker, queue: :mail, max_attempts: 3

  alias Flux.Repo
  alias Flux.WebPush
  alias Flux.WebPush.Subscription

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id, "title" => title} = args}) do
    case Repo.get(Subscription, id) do
      nil ->
        :ok

      subscription ->
        payload = %{"title" => "FluxCapacitor", "body" => title, "path" => args["path"]}

        case WebPush.push(subscription, payload) do
          :ok ->
            :ok

          {:error, :gone} ->
            Repo.delete(subscription)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
