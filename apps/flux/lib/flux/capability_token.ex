defmodule Flux.CapabilityToken do
  @moduledoc """
  At-rest hashing for capability tokens (site/share/webhook/download
  links): only `:crypto.hash(:sha256, token)` is used to authorize a
  presented token, mirroring `ApiToken`/`Invitation`'s `token_hash`
  pattern.

  Unlike those two, the plaintext column stays put for now — the console
  re-displays these URLs on demand (site embed snippets, webhook URLs,
  share links, download links) rather than showing them once at mint, and
  moving to a reveal-once + regenerate flow is its own UI project. So
  this only closes the "authorization by direct plaintext-column
  comparison" surface; it does not yet stop a DB read from also handing
  over the live token. See docs/PARITY-PLAN.md #73.
  """

  @doc "SHA-256 digest of a presented/minted token, for a `*_token_hash` column."
  @spec hash(String.t()) :: binary()
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)
end
