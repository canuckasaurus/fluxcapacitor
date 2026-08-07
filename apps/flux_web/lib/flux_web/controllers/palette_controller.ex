defmodule FluxWeb.PaletteController do
  @moduledoc """
  Feeds the Ctrl+K command palette: console pages plus the workspace's
  fluxes, apps, datasets, labeling projects, and doc templates as
  `{label, kind, url}` entries. Fetched once per palette open; filtering
  happens client-side.
  """
  use FluxWeb, :controller

  @pages [
    {"Dashboard", "/console"},
    {"Flux Creator", "/console/fluxes"},
    {"Apps", "/console/apps"},
    {"Doc templates", "/console/templates"},
    {"Interviews", "/console/interviews"},
    {"Knowledge", "/console/knowledge"},
    {"Tools", "/console/tools"},
    {"Labeling", "/console/labeling"},
    {"Plugins", "/console/plugins"},
    {"Runs", "/console/runs"},
    {"Files", "/console/files"},
    {"Notifications", "/console/notifications"},
    {"Members", "/console/members"},
    {"Audit log", "/console/audit"},
    {"Workspace settings", "/console/settings"},
    {"Docs", "/console/docs"}
  ]

  def index(conn, _params) do
    case conn.assigns[:current_scope] do
      %{workspace: %{id: _id}} = scope -> json(conn, %{entries: entries(scope)})
      _no_workspace -> json(conn, %{entries: []})
    end
  end

  defp entries(scope) do
    pages = for {label, url} <- @pages, do: %{label: label, kind: "page", url: url}

    fluxes =
      for flux <- Flux.Workflows.list_workflows(scope) do
        %{label: flux.name, kind: "flux", url: "/console/fluxes/#{flux.id}"}
      end

    apps =
      for app <- Flux.Chat.list_apps(scope) do
        %{label: app.name, kind: "app", url: "/console/apps/#{app.id}"}
      end

    datasets =
      for dataset <- rag().list_datasets(scope) do
        %{label: dataset.name, kind: "dataset", url: "/console/knowledge"}
      end

    projects =
      for project <- Flux.Labeling.list_projects(scope) do
        %{label: project.name, kind: "labeling", url: "/console/labeling"}
      end

    templates =
      for template <- Flux.DocTemplates.list(scope) do
        %{label: template.name, kind: "template", url: "/console/templates"}
      end

    pages ++ fluxes ++ apps ++ datasets ++ projects ++ templates
  end

  defp rag, do: Application.get_env(:flux, :rag_module, Flux.RAG)
end
