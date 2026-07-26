defmodule Flux.Encrypted.Binary do
  @moduledoc "Cloak-encrypted binary column type backed by `Flux.Vault`."
  use Cloak.Ecto.Binary, vault: Flux.Vault
end
