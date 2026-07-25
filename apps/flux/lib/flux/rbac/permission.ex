defmodule Flux.RBAC.Permission do
  @moduledoc """
  The catalog of permission points, ported 1:1 from Dify's
  `api/core/rbac/entities.py` (`RBACPermission`, 45 points across the
  `app`, `dataset`, and `workspace` scopes).

  Permission names are compile-time atoms; `valid?/1` and `all/0` are the
  single source of truth for custom-role storage and the roles UI.
  """

  @app_permissions ~w(
    app_view_layout
    app_test_and_run
    app_preview
    app_create_and_management
    app_release_and_version
    app_import_export_dsl
    app_edit
    app_monitor
    app_tracing_config
    app_log_and_annotation
    app_delete
    app_access_config
  )a

  @dataset_permissions ~w(
    dataset_preview
    dataset_readonly
    dataset_edit
    dataset_create_and_management
    dataset_pipeline_test
    dataset_document_download
    dataset_retrieval_recall
    dataset_use
    dataset_delete_file
    dataset_pipeline_release
    dataset_delete
    dataset_access_config
    dataset_api_key_manage
    dataset_external_connect
    dataset_import_export_dsl
  )a

  @workspace_permissions ~w(
    workspace_member_manage
    workspace_role_manage
    api_extension_manage
    customization_manage
    agent_manage
    snippets_create_and_modify
    snippets_management
    plugin_install
    plugin_preferences
    plugin_model_config
    plugin_manage
    plugin_delete
    plugin_debug
    credential_use
    credential_create
    credential_manage
    tool_manage
    mcp_manage
  )a

  @all @app_permissions ++ @dataset_permissions ++ @workspace_permissions
  @all_set MapSet.new(@all)

  @type t ::
          unquote(
            @all
            |> Enum.map_join(" | ", &inspect/1)
            |> Code.string_to_quoted!()
          )

  def all, do: @all
  def app_scope, do: @app_permissions
  def dataset_scope, do: @dataset_permissions
  def workspace_scope, do: @workspace_permissions

  def valid?(permission), do: MapSet.member?(@all_set, permission)

  def scope_of(permission) when permission in @app_permissions, do: :app
  def scope_of(permission) when permission in @dataset_permissions, do: :dataset
  def scope_of(permission) when permission in @workspace_permissions, do: :workspace
end
