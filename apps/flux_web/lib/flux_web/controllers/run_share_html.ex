defmodule FluxWeb.RunShareHTML do
  @moduledoc false
  use FluxWeb, :html

  def show(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6 space-y-4">
      <div class="flex items-center gap-2">
        <.icon name="hero-bolt-solid" class="size-6 flux-bolt" />
        <span class="text-xl flux-wordmark">FluxCapacitor</span>
        <span class="badge badge-ghost badge-sm">shared run trace · read-only</span>
      </div>

      <div class="card border border-base-200 p-4 space-y-1">
        <h1 class="font-semibold">{@workflow_name}</h1>
        <p class="text-sm opacity-70">
          Run <span class="font-mono text-xs">{@run.id}</span>
          · {@run.status} · {@run.source}
          <span :if={@run.version}>· v{@run.version}</span>
          <span :if={@run.elapsed_ms}>· {@run.elapsed_ms} ms</span>
          · {Calendar.strftime(@run.inserted_at, "%Y-%m-%d %H:%M:%S")} UTC
        </p>
        <p :if={@run.error} class="text-sm text-error">{@run.error}</p>
      </div>

      <div class="card border border-base-200 p-4 space-y-2">
        <h2 class="text-sm font-semibold">Inputs</h2>
        <pre class="rounded bg-base-200 p-2 text-xs overflow-x-auto">{Jason.encode!(@run.inputs, pretty: true)}</pre>
        <h2 class="text-sm font-semibold">Outputs</h2>
        <pre class="rounded bg-base-200 p-2 text-xs overflow-x-auto">{Jason.encode!(@run.outputs, pretty: true)}</pre>
      </div>

      <div class="card border border-base-200 p-4 space-y-2">
        <h2 class="text-sm font-semibold">Node executions ({length(@run.node_executions)})</h2>
        <div
          :for={node <- @run.node_executions}
          class="rounded border border-base-200 p-2 text-xs space-y-1"
        >
          <p class="font-mono">
            {node["node_id"]}
            <span class="badge badge-ghost badge-xs">{node["type"]}</span>
            <span class={[
              "badge badge-xs",
              (node["status"] == "succeeded" && "badge-success") || "badge-error"
            ]}>
              {node["status"]}
            </span>
            <span :if={node["elapsed_ms"]} class="opacity-60">{node["elapsed_ms"]} ms</span>
          </p>
          <pre
            :if={node["outputs"] not in [nil, %{}]}
            class="rounded bg-base-200 p-2 overflow-x-auto max-h-48 overflow-y-auto"
          >{Jason.encode!(node["outputs"], pretty: true)}</pre>
          <p :if={node["error"]} class="text-error">{node["error"]}</p>
        </div>
      </div>

      <p class="text-xs opacity-50">
        This link expires 30 days after it was created.
      </p>
    </div>
    """
  end
end
