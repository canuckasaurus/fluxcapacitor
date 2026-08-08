defmodule FluxWeb.StatusController do
  @moduledoc """
  Public status page: component health from the doctor checks (names and
  states only, no internals) plus an admin-editable incident note. Also
  answers JSON for scripted checks (`accept: application/json`).
  """
  use FluxWeb, :controller

  def show(conn, _params) do
    {components, note, operational?} = snapshot()
    render(conn, :show, components: components, note: note, operational?: operational?)
  end

  def show_json(conn, _params) do
    {components, note, operational?} = snapshot()

    json(conn, %{
      status: (operational? && "operational") || "degraded",
      components: components,
      note: note
    })
  end

  defp snapshot do
    components =
      for {name, result} <- Flux.Doctor.checks() do
        %{name: name, state: state(result)}
      end

    {components, Flux.InstanceSettings.get("status_note"),
     Enum.all?(components, &(&1.state != "down"))}
  end

  defp state(:ok), do: "ok"
  defp state(:skipped), do: "not configured"
  defp state({:error, _detail}), do: "down"
  defp state(_other), do: "down"
end
