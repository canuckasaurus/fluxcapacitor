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

  def index(conn, params) do
    case {conn.assigns[:current_scope], String.trim(to_string(params["q"] || ""))} do
      {%{workspace: %{id: _id}} = scope, ""} ->
        json(conn, %{entries: entries(scope)})

      # A query switches to deep search: conversations and runs are too
      # numerous for the static list, so they resolve server-side.
      {%{workspace: %{id: _id}} = scope, query} when byte_size(query) >= 3 ->
        json(conn, %{entries: deep_entries(scope, query)})

      {%{workspace: %{id: _id}}, _too_short} ->
        json(conn, %{entries: []})

      _no_workspace ->
        json(conn, %{entries: []})
    end
  end

  defp deep_entries(scope, query) do
    conversations =
      for conversation <- Flux.Chat.search_conversation_titles(scope, query, 8) do
        %{
          label: conversation.title || "Untitled conversation",
          kind: "conversation",
          url: "/console/apps/#{conversation.app_id}/monitor?conversation=#{conversation.id}"
        }
      end

    runs =
      for %{run: run, workflow_name: name} <-
            Flux.Workflows.list_workspace_runs(scope, %{q: query}, 8) do
        %{
          label: "#{name} run · #{Calendar.strftime(run.inserted_at, "%b %d %H:%M")}",
          kind: "run",
          url: "/console/runs?run=#{run.id}"
        }
      end

    conversations ++ runs
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

    # Other workspaces switch via POST (the palette JS builds the form).
    workspaces =
      for {workspace, _membership} <- Flux.Accounts.list_workspaces(scope.account),
          workspace.id != scope.workspace.id do
        %{
          label: "Switch to #{workspace.name}",
          kind: "workspace",
          url: "/console/workspaces/switch/#{workspace.id}"
        }
      end

    pages ++ workspaces ++ fluxes ++ apps ++ datasets ++ projects ++ templates
  end

  defp rag, do: Application.get_env(:flux, :rag_module, Flux.RAG)
end
