defmodule FluxWeb.DocTemplateController do
  @moduledoc "Word doc-template downloads: the original file and test renders."
  use FluxWeb, :controller

  alias Flux.DocTemplates
  alias Flux.DocTemplates.DocTemplate

  @docx_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  def file(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with %DocTemplate{kind: "docx", file_key: key, name: name} <-
           DocTemplates.get(scope, id),
         {:ok, binary} <- Flux.Storage.get(key) do
      send_download(conn, {:binary, binary},
        filename: "#{name}.docx",
        content_type: @docx_type
      )
    else
      _missing -> not_a_word_template(conn)
    end
  end

  def test_render(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    context =
      case Jason.decode(params["context"] || "") do
        {:ok, %{} = context} -> context
        _blank_or_invalid -> %{}
      end

    with %DocTemplate{kind: "docx", file_key: key, name: name} <-
           DocTemplates.get(scope, id),
         {:ok, binary} <- Flux.Storage.get(key),
         {:ok, filled} <- Flux.Engine.Docx.render(binary, context) do
      send_download(conn, {:binary, filled},
        filename: "#{name} (test).docx",
        content_type: @docx_type
      )
    else
      {:error, message} when is_binary(message) ->
        conn
        |> put_flash(:error, "Render failed: #{message}")
        |> redirect(to: ~p"/console/templates")

      _missing ->
        not_a_word_template(conn)
    end
  end

  defp not_a_word_template(conn) do
    conn
    |> put_flash(:error, "That Word template no longer exists.")
    |> redirect(to: ~p"/console/templates")
  end
end
