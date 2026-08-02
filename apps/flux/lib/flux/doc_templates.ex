defmodule Flux.DocTemplates do
  @moduledoc """
  User-provided document templates: reusable Jinja documents (offer
  letters, reports, emails, invoices) that template and document nodes
  plug into via `template_id`. The library lives per workspace.

  Templates are **canonical**: once created, their content/file never
  changes — a node pinned to a template renders exactly what was
  reviewed, forever. Revisions are **forks**: new templates that record
  their `parent_id` lineage. Only name/description are mutable in place.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.RBAC
  alias Flux.Repo

  defmodule DocTemplate do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "doc_templates" do
      belongs_to :workspace, Flux.Accounts.Workspace
      belongs_to :parent, __MODULE__
      field :name, :string
      field :description, :string
      field :content, :string
      field :kind, :string, default: "text"
      field :file_key, :string
      field :variables, {:array, :string}, default: []

      timestamps(type: :utc_datetime)
    end

    @doc "Metadata-only changes — canonical content never moves."
    def metadata_changeset(template, attrs) do
      template
      |> cast(attrs, [:name, :description])
      |> validate_required([:name])
      |> validate_length(:name, min: 1, max: 120)
      |> unique_constraint([:workspace_id, :name])
    end

    def changeset(template, attrs) do
      template
      |> cast(attrs, [:name, :description, :content])
      |> validate_required([:name])
      |> validate_length(:name, min: 1, max: 120)
      |> validate_length(:content, max: 100_000)
      |> then(fn changeset ->
        if get_field(changeset, :kind) == "docx" do
          changeset
        else
          changeset |> validate_required([:content]) |> validate_jinja()
        end
      end)
      |> unique_constraint([:workspace_id, :name])
    end

    # Saving a template that cannot parse would only fail later at run
    # time — reject it here with the renderer's own message.
    defp validate_jinja(changeset) do
      validate_change(changeset, :content, fn :content, content ->
        case Flux.Engine.Jinja.render(content, %{}) do
          {:ok, _output} -> []
          {:error, message} -> [content: "invalid template: #{message}"]
        end
      end)
    end
  end

  def list(%Scope{} = scope) do
    DocTemplate |> Repo.scoped(scope) |> order_by([t], asc: t.name) |> Repo.all()
  end

  def get(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(DocTemplate, id: ^id), scope)) || {:error, :not_found}
  end

  def create(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         {:ok, template} <-
           %DocTemplate{workspace_id: Scope.workspace_id(scope)}
           |> DocTemplate.changeset(attrs)
           |> Repo.insert() do
      Flux.Audit.record(scope, "doc_template.create",
        resource_type: "doc_template",
        resource_id: template.id,
        metadata: %{"name" => template.name}
      )

      {:ok, template}
    end
  end

  @doc """
  Renames/re-describes a template. Content is canonical and cannot be
  updated — revise by forking instead.
  """
  def update(%Scope{} = scope, %DocTemplate{} = template, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- template.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, updated} <- template |> DocTemplate.metadata_changeset(attrs) |> Repo.update() do
      Flux.Audit.record(scope, "doc_template.update",
        resource_type: "doc_template",
        resource_id: template.id,
        metadata: %{"name" => updated.name}
      )

      {:ok, updated}
    end
  end

  @doc """
  Forks a text template: a new canonical template whose lineage points
  at the parent. Nodes bound to the parent keep rendering the parent.
  """
  def fork(%Scope{} = scope, %DocTemplate{kind: "text"} = parent, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- parent.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, template} <-
           %DocTemplate{workspace_id: Scope.workspace_id(scope), parent_id: parent.id}
           |> DocTemplate.changeset(attrs)
           |> Repo.insert() do
      audit_fork(scope, template, parent)
      {:ok, template}
    end
  end

  def fork(%Scope{}, %DocTemplate{}, _attrs),
    do: {:error, "Word templates fork by uploading a revision"}

  @doc """
  Forks a Word template: with `binary`, the revision is validated and
  stored as the new canonical file; without, the parent's bytes are
  copied (a rename/branch point).
  """
  def fork_docx(%Scope{} = scope, %DocTemplate{kind: "docx"} = parent, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- parent.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, binary} <- fork_binary(parent, attrs[:binary]),
         :ok <- check_docx_size(binary),
         {:ok, variables} <- validate_docx(binary) do
      key = "doc_templates/#{Scope.workspace_id(scope)}/#{Ecto.UUID.generate()}.docx"

      changeset =
        %DocTemplate{
          workspace_id: Scope.workspace_id(scope),
          parent_id: parent.id,
          kind: "docx",
          file_key: key,
          variables: variables
        }
        |> DocTemplate.changeset(Map.take(attrs, [:name, :description]))

      with {:ok, template} <- Repo.insert(changeset),
           :ok <- Flux.Storage.put(key, binary) do
        audit_fork(scope, template, parent)
        {:ok, template}
      end
    end
  end

  def fork_docx(%Scope{}, %DocTemplate{}, _attrs),
    do: {:error, "only Word templates fork with a file"}

  defp fork_binary(_parent, binary) when is_binary(binary), do: {:ok, binary}
  defp fork_binary(%DocTemplate{file_key: key}, _none), do: Flux.Storage.get(key)

  defp audit_fork(scope, template, parent) do
    Flux.Audit.record(scope, "doc_template.fork",
      resource_type: "doc_template",
      resource_id: template.id,
      metadata: %{"name" => template.name, "parent_id" => parent.id, "parent" => parent.name}
    )
  end

  @doc """
  Creates a Word-document template from an uploaded .docx: the Jinja
  inside is validated and its variables discovered before anything is
  stored, so a broken template never reaches a run.
  """
  def create_docx(%Scope{} = scope, %{binary: binary} = attrs) when is_binary(binary) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         :ok <- check_docx_size(binary),
         {:ok, variables} <- validate_docx(binary) do
      key = "doc_templates/#{Scope.workspace_id(scope)}/#{Ecto.UUID.generate()}.docx"

      changeset =
        %DocTemplate{
          workspace_id: Scope.workspace_id(scope),
          kind: "docx",
          file_key: key,
          variables: variables
        }
        |> DocTemplate.changeset(Map.take(attrs, [:name, :description]))

      with {:ok, template} <- Repo.insert(changeset),
           :ok <- Flux.Storage.put(key, binary) do
        Flux.Audit.record(scope, "doc_template.create",
          resource_type: "doc_template",
          resource_id: template.id,
          metadata: %{"name" => template.name, "kind" => "docx"}
        )

        {:ok, template}
      end
    end
  end

  @max_docx_bytes 10 * 1024 * 1024
  defp check_docx_size(binary) when byte_size(binary) <= @max_docx_bytes, do: :ok
  defp check_docx_size(_binary), do: {:error, "the template is larger than 10 MB"}

  defp validate_docx(binary) do
    case Flux.Engine.Docx.extract_tags(binary) do
      {:ok, variables} -> {:ok, variables}
      {:error, message} -> {:error, message}
    end
  end

  def delete(%Scope{} = scope, id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %DocTemplate{} = template <-
           Repo.one(Repo.scoped(where(DocTemplate, id: ^id), scope)) || {:error, :not_found},
         {:ok, deleted} <- Repo.delete(template) do
      if template.file_key, do: Flux.Storage.delete(template.file_key)

      Flux.Audit.record(scope, "doc_template.delete",
        resource_type: "doc_template",
        resource_id: template.id,
        metadata: %{"name" => template.name}
      )

      {:ok, deleted}
    end
  end

  @doc """
  Scaffolds an interview flux from a Word template: a start form asking
  for every discovered variable, a document node filling the template,
  and an end node exposing the download — the one-click docassemble.
  """
  def create_interview_flux(%Scope{} = scope, %DocTemplate{kind: "docx"} = template) do
    variables =
      for name <- template.variables, name not in ~w(sys env conversation start) do
        %{
          "name" => name,
          "label" => humanize(name),
          "type" => "text",
          "required" => true
        }
      end

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Interview",
          "position" => %{"x" => 80, "y" => 120},
          "config" => %{"variables" => variables}
        },
        %{
          "id" => "document_1",
          "type" => "document",
          "title" => "Fill #{template.name}",
          "position" => %{"x" => 380, "y" => 120},
          "config" => %{"template_id" => template.id, "output_name" => template.name}
        },
        %{
          "id" => "end",
          "type" => "end",
          "title" => "End",
          "position" => %{"x" => 680, "y" => 120},
          "config" => %{
            "outputs" => [
              %{"key" => "document_url", "value" => "{{document_1.url}}"},
              %{"key" => "document_name", "value" => "{{document_1.name}}"}
            ]
          }
        }
      ],
      "edges" => [
        %{
          "id" => "edge_1",
          "source" => "start",
          "source_handle" => "default",
          "target" => "document_1"
        },
        %{
          "id" => "edge_2",
          "source" => "document_1",
          "source_handle" => "default",
          "target" => "end"
        }
      ]
    }

    with {:ok, workflow} <-
           Flux.Workflows.create_workflow(scope, %{"name" => "#{template.name} interview"}),
         {:ok, workflow} <- Flux.Workflows.update_draft(scope, workflow, graph) do
      {:ok, workflow}
    end
  end

  def create_interview_flux(%Scope{}, %DocTemplate{}),
    do: {:error, "only Word templates scaffold an interview"}

  # snake_case / camelCase variable names become form labels.
  defp humanize(name) do
    name
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.replace(["_", "-"], " ")
    |> String.trim()
    |> String.capitalize()
  end

  @doc "Content lookup for the engine's fetch_doc_template capability."
  def fetch_content(workspace_id, template_id) do
    case fetch(workspace_id, template_id) do
      {:ok, %DocTemplate{kind: "docx"}} ->
        {:error, "that template is a Word document — use a document node"}

      {:ok, %DocTemplate{content: content}} ->
        {:ok, content}

      error ->
        error
    end
  end

  @doc "Docx bytes lookup for the engine's fetch_docx_template capability."
  def fetch_docx(workspace_id, template_id) do
    with {:ok, %DocTemplate{kind: "docx", file_key: key, name: name}} <-
           fetch(workspace_id, template_id),
         {:ok, binary} <- Flux.Storage.get(key) do
      {:ok, %{binary: binary, name: name}}
    else
      {:ok, %DocTemplate{}} -> {:error, "that template is text — use a template node"}
      {:error, _reason} -> {:error, "doc template not found"}
    end
  end

  defp fetch(workspace_id, template_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(to_string(template_id)),
         %DocTemplate{} = template <-
           Repo.one(
             from(t in DocTemplate,
               where: t.workspace_id == ^workspace_id and t.id == ^template_id
             )
           ) do
      {:ok, template}
    else
      _missing -> {:error, "doc template not found"}
    end
  end
end
