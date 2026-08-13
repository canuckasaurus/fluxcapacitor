defmodule Flux.IPAllowlist do
  @moduledoc """
  Optional per-workspace CIDR allowlist for the service API. Stored in
  workspace `custom_config["ip_allowlist"]` as a list of entries like
  `"203.0.113.0/24"`, `"198.51.100.7"` (bare address = /32), or IPv6
  equivalents. Empty or unset means every address is welcome.

  Note for reverse-proxy deployments: the check runs on the socket's
  remote address, so the proxy must be configured to pass the client
  address through (e.g. a `remote_ip`-rewriting plug) for the list to
  mean client addresses rather than the proxy's.
  """

  import Bitwise

  alias Flux.Accounts.Scope
  alias Flux.Accounts.Workspace
  alias Flux.Repo

  @doc "The configured CIDR list, or [] when the allowlist is off."
  def list(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %{custom_config: %{"ip_allowlist" => cidrs}} when is_list(cidrs) -> cidrs
      _off -> []
    end
  end

  @doc """
  Saves the allowlist from newline-separated text (blank turns it off).
  Every entry must parse as an address or CIDR or the save is refused —
  a typo that silently allowed nobody would be a lockout.
  """
  def configure(%Scope{} = scope, text) do
    entries =
      text
      |> to_string()
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.find(entries, &(parse(&1) == :error)) do
      nil ->
        with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
             %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
          custom_config =
            if entries == [] do
              Map.delete(workspace.custom_config || %{}, "ip_allowlist")
            else
              Map.put(workspace.custom_config || %{}, "ip_allowlist", entries)
            end

          workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update()
        end

      invalid ->
        {:error, {:invalid_cidr, invalid}}
    end
  end

  @doc "Whether `ip` (an `:inet` tuple) may use this workspace's service API."
  def allowed?(workspace_id, ip) when is_tuple(ip) do
    case list(workspace_id) do
      [] -> true
      cidrs -> Enum.any?(cidrs, &ip_in_cidr?(ip, &1))
    end
  end

  def allowed?(_workspace_id, _ip), do: false

  @doc false
  def parse(entry) do
    {address_part, bits_part} =
      case String.split(entry, "/", parts: 2) do
        [address, bits] -> {address, bits}
        [address] -> {address, nil}
      end

    with {:ok, address} <- :inet.parse_strict_address(String.to_charlist(address_part)),
         {:ok, bits} <- parse_bits(bits_part, address) do
      {:ok, address, bits}
    else
      _invalid -> :error
    end
  end

  defp parse_bits(nil, address), do: {:ok, max_bits(address)}

  defp parse_bits(text, address) do
    case Integer.parse(text) do
      {bits, ""} when bits >= 0 ->
        if bits <= max_bits(address), do: {:ok, bits}, else: :error

      _invalid ->
        :error
    end
  end

  defp max_bits({_a, _b, _c, _d}), do: 32
  defp max_bits(_ipv6), do: 128

  defp ip_in_cidr?(ip, cidr) do
    case parse(cidr) do
      {:ok, network, bits} ->
        tuple_size(ip) == tuple_size(network) and
          prefix(ip, bits) == prefix(network, bits)

      :error ->
        false
    end
  end

  # The address as an integer, shifted so only the first `bits` count.
  defp prefix(address, bits) do
    total = max_bits(address)
    chunk = if total == 32, do: 8, else: 16

    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> acc * (1 <<< chunk) + part end)
    |> bsr(total - bits)
  end
end
