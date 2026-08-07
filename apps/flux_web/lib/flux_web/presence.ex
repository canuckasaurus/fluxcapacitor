defmodule FluxWeb.Presence do
  @moduledoc """
  Who's here — currently tracks editors per flux canvas so two people
  stop silently overwriting each other's drafts.
  """
  use Phoenix.Presence, otp_app: :flux_web, pubsub_server: Flux.PubSub
end
