defmodule FluxWeb.Plugs.Locale do
  @moduledoc """
  Picks the UI locale for the request: an explicit `?locale=` param wins
  (and is remembered in the session), then the session, then the
  workspace default locale (set in workspace settings), then the
  Accept-Language header. Unknown locales fall back to the default.

  Also usable as a LiveView `on_mount` hook so LiveView processes pick
  up the locale the plug stored in the session.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    candidates =
      [
        conn.params["locale"],
        get_session(conn, :locale),
        workspace_locale(conn) | accept_languages(conn)
      ]

    case first_known(candidates) do
      nil ->
        conn

      locale ->
        Gettext.put_locale(FluxWeb.Gettext, locale)
        put_session(conn, :locale, locale)
    end
  end

  def on_mount(:default, _params, session, socket) do
    if locale = session["locale"] do
      Gettext.put_locale(FluxWeb.Gettext, locale)
    end

    {:cont, socket}
  end

  defp first_known(candidates) do
    known = Gettext.known_locales(FluxWeb.Gettext)

    Enum.find_value(candidates, fn
      nil ->
        nil

      candidate ->
        candidate = String.downcase(to_string(candidate))
        base = candidate |> String.split("-") |> hd()
        Enum.find(known, &(&1 == candidate)) || Enum.find(known, &(&1 == base))
    end)
  end

  # The workspace default fills in for members who never picked a locale;
  # the pipeline runs this plug after the scope fetch, so no extra query.
  defp workspace_locale(conn) do
    case conn.assigns[:current_scope] do
      %{workspace: %{custom_config: %{"locale" => locale}}} when is_binary(locale) -> locale
      _no_workspace -> nil
    end
  end

  defp accept_languages(conn) do
    conn
    |> get_req_header("accept-language")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(fn part -> part |> String.split(";") |> hd() |> String.trim() end)
  end
end
