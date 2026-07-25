defmodule FluxWeb.ConsoleLive.WorkspaceNew do
  @moduledoc false
  use FluxWeb, :live_view

  alias Flux.Accounts
  alias Flux.Accounts.Workspace

  @impl true
  def mount(_params, _session, socket) do
    changeset = Workspace.changeset(%Workspace{}, %{})

    {:ok,
     assign(socket,
       page_title: "Create workspace",
       form: to_form(changeset)
     )}
  end

  @impl true
  def handle_event("validate", %{"workspace" => params}, socket) do
    changeset =
      %Workspace{}
      |> Workspace.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"workspace" => params}, socket) do
    case Accounts.create_workspace(socket.assigns.current_scope.account, params) do
      {:ok, {workspace, _membership}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace \"#{workspace.name}\" created. Welcome!")
         |> redirect(to: ~p"/console")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="min-h-screen bg-base-100 flex items-center justify-center px-4">
      <div class="w-full max-w-md space-y-6">
        <div class="text-center space-y-2">
          <.icon name="hero-bolt-solid" class="size-9 text-primary mx-auto" />
          <h1 class="text-2xl font-bold">Create your workspace</h1>
          <p class="opacity-70 text-sm">
            A workspace is where your team builds Fluxes, manages knowledge, and shares
            plugins. You can create more later or join one by invitation.
          </p>
        </div>

        <.form
          for={@form}
          id="workspace-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Workspace name"
            placeholder="e.g. Platform Engineering"
          />
          <button class="btn btn-primary w-full">Create workspace</button>
        </.form>
      </div>
    </div>
    """
  end
end
