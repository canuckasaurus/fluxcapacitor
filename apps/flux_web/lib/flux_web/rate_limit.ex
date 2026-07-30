defmodule FluxWeb.RateLimit do
  @moduledoc "ETS-backed rate limiter (hammer)."
  use Hammer, backend: :ets
end
