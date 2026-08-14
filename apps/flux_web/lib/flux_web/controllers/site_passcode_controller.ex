defmodule FluxWeb.SitePasscodeController do
  @moduledoc """
  Verifies a public-site passcode and remembers the pass in the signed
  session cookie (`site_pass:<app_id>`), then sends the visitor back to
  the site. Wrong codes bounce back with a flash the LiveView shows.
  """
  use FluxWeb, :controller

  alias Flux.Chat

  def verify(conn, %{"token" => token} = params) do
    case Chat.get_app_by_site_token(token) do
      {:ok, app} ->
        if Chat.site_passcode_ok?(app, params["passcode"]) do
          conn
          |> put_session("site_pass:#{app.id}", true)
          |> redirect(to: ~p"/site/#{token}")
        else
          conn
          |> put_flash(:error, "That passcode didn't match.")
          |> redirect(to: ~p"/site/#{token}")
        end

      _maintenance_or_missing ->
        redirect(conn, to: ~p"/site/#{token}")
    end
  end

  @doc "Same contract for published flux form pages (`/site/flux/:token`)."
  def verify_flux(conn, %{"token" => token} = params) do
    case Flux.Workflows.get_workflow_by_site_token(token) do
      {:ok, workflow} ->
        if Flux.Workflows.site_passcode_ok?(workflow, params["passcode"]) do
          conn
          |> put_session("site_pass:#{workflow.id}", true)
          |> redirect(to: ~p"/site/flux/#{token}")
        else
          conn
          |> put_flash(:error, "That passcode didn't match.")
          |> redirect(to: ~p"/site/flux/#{token}")
        end

      _missing ->
        redirect(conn, to: ~p"/site/flux/#{token}")
    end
  end
end
