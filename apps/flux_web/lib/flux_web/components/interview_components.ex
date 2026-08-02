defmodule FluxWeb.InterviewComponents do
  @moduledoc """
  The interview answer form — one field per question, rendered
  identically wherever a paused run asks for input (console run panel
  and public flux sites).
  """
  use Phoenix.Component

  attr :questions, :list, required: true
  attr :errors, :map, default: %{}

  def interview_fields(assigns) do
    ~H"""
    <div class="space-y-3">
      <div :for={question <- @questions} class="form-control">
        <label class="label-text text-sm font-semibold mb-1" for={"iv-#{question["name"]}"}>
          {question["label"]}
          <span :if={question["required"]} class="text-error">*</span>
        </label>

        <input
          :if={question["type"] in ["text", nil]}
          type="text"
          id={"iv-#{question["name"]}"}
          name={question["name"]}
          class="input input-sm input-bordered w-full"
        />
        <textarea
          :if={question["type"] == "textarea"}
          id={"iv-#{question["name"]}"}
          name={question["name"]}
          rows="3"
          class="textarea textarea-bordered textarea-sm w-full"
        ></textarea>
        <input
          :if={question["type"] == "number"}
          type="number"
          step="any"
          id={"iv-#{question["name"]}"}
          name={question["name"]}
          class="input input-sm input-bordered w-full"
        />
        <select
          :if={question["type"] == "select"}
          id={"iv-#{question["name"]}"}
          name={question["name"]}
          class="select select-sm select-bordered w-full"
        >
          <option value="">Choose…</option>
          <option :for={option <- List.wrap(question["options"])} value={option}>
            {option}
          </option>
        </select>
        <label :if={question["type"] == "boolean"} class="label cursor-pointer justify-start gap-2">
          <input
            type="checkbox"
            id={"iv-#{question["name"]}"}
            name={question["name"]}
            class="checkbox checkbox-sm"
          />
          <span class="label-text text-sm">Yes</span>
        </label>

        <p :if={to_string(question["help"] || "") != ""} class="text-xs opacity-60 mt-1">
          {question["help"]}
        </p>
        <p :if={@errors[question["name"]]} class="text-xs text-error mt-1">
          {@errors[question["name"]]}
        </p>
      </div>
    </div>
    """
  end
end
