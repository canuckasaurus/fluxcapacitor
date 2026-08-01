defmodule Flux.Plugin.Trigger do
  @moduledoc """
  Behaviour for trigger plugins: pollable event sources that start flux
  runs. The platform polls `c:poll/2` on a schedule with the cursor it
  stored last time; each returned event becomes one run, its map merged
  into the run's start inputs. Return the events oldest-first when order
  matters.

  The cursor is an opaque string the plugin defines (a feed item id, an
  API watermark, a timestamp) — `nil` on the very first poll, which
  plugins should treat as "prime the cursor, emit nothing" so history
  isn't replayed.
  """

  @type credentials :: %{optional(String.t()) => String.t()}
  @type cursor :: String.t() | nil
  @type event :: %{optional(String.t()) => term()}

  @callback poll(credentials, cursor) :: {:ok, [event], cursor} | {:error, term()}
end
