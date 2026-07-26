defmodule Flux.Vault do
  @moduledoc """
  The master-key vault (Cloak). It encrypts exactly one thing: per-workspace
  data-encryption keys in `workspace_keys`. Everything credential-shaped is
  encrypted with the workspace DEK via `Flux.Crypto`, so rotating the master
  key only re-wraps DEK rows, and deleting a workspace's DEK crypto-shreds
  all of its secrets.
  """
  use Cloak.Vault, otp_app: :flux
end
