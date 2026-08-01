defmodule FluxWeb.V1.ApiSpec do
  @moduledoc """
  OpenAPI schemas for the `/v1` service API. Contract tests assert every
  controller response against these shapes, so a change that breaks
  interoperability fails CI instead of surprising API consumers.
  """
  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi}

  defmodule Schemas do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    defmodule Error do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "Error",
        type: :object,
        properties: %{
          code: %Schema{type: :string},
          message: %Schema{type: :string},
          status: %Schema{type: :integer}
        },
        required: [:code, :message, :status],
        additionalProperties: false
      })
    end

    defmodule ChatMessage do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ChatMessage",
        description: "Blocking response of /v1/chat-messages and /v1/completion-messages",
        type: :object,
        properties: %{
          event: %Schema{type: :string, enum: ["message"]},
          message_id: %Schema{type: :string, format: :uuid},
          conversation_id: %Schema{type: :string, format: :uuid},
          mode: %Schema{type: :string},
          answer: %Schema{type: :string},
          metadata: %Schema{
            type: :object,
            properties: %{usage: %Schema{type: :object}},
            required: [:usage]
          },
          created_at: %Schema{type: :integer}
        },
        required: [:event, :message_id, :conversation_id, :mode, :answer, :metadata, :created_at],
        additionalProperties: false
      })
    end

    defmodule WorkflowRun do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "WorkflowRun",
        description: "Blocking response of /v1/workflows/run",
        type: :object,
        properties: %{
          workflow_run_id: %Schema{type: :string, format: :uuid},
          data: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              workflow_id: %Schema{type: :string, format: :uuid},
              status: %Schema{
                type: :string,
                enum: ["succeeded", "failed", "stopped", "running", "paused"]
              },
              outputs: %Schema{type: :object, nullable: true},
              error: %Schema{type: :string, nullable: true},
              paused_prompt: %Schema{type: :object, nullable: true},
              elapsed_time: %Schema{type: :number, nullable: true},
              created_at: %Schema{type: :integer}
            },
            required: [:id, :workflow_id, :status, :outputs, :created_at],
            additionalProperties: false
          }
        },
        required: [:workflow_run_id, :data],
        additionalProperties: false
      })
    end

    defmodule Parameters do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "Parameters",
        type: :object,
        properties: %{
          opening_statement: %Schema{type: :string, nullable: true},
          suggested_questions: %Schema{type: :array, items: %Schema{type: :string}},
          user_input_form: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              description: "One control keyed by its type (text-input/paragraph/number)",
              additionalProperties: %Schema{
                type: :object,
                properties: %{
                  label: %Schema{type: :string},
                  variable: %Schema{type: :string},
                  required: %Schema{type: :boolean},
                  default: %Schema{type: :string}
                },
                required: [:label, :variable, :required],
                additionalProperties: false
              }
            }
          },
          model: %Schema{
            type: :object,
            properties: %{
              provider: %Schema{type: :string},
              name: %Schema{type: :string}
            },
            required: [:provider, :name],
            additionalProperties: false
          }
        },
        required: [:opening_statement, :suggested_questions, :user_input_form, :model],
        additionalProperties: false
      })
    end

    defmodule ConversationList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ConversationList",
        type: :object,
        properties: %{
          limit: %Schema{type: :integer},
          has_more: %Schema{type: :boolean},
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                name: %Schema{type: :string, nullable: true},
                created_at: %Schema{type: :integer}
              },
              required: [:id, :created_at],
              additionalProperties: false
            }
          }
        },
        required: [:limit, :has_more, :data],
        additionalProperties: false
      })
    end

    defmodule MessageList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "MessageList",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                conversation_id: %Schema{type: :string, format: :uuid},
                role: %Schema{type: :string, enum: ["user", "assistant"]},
                content: %Schema{type: :string},
                status: %Schema{
                  type: :string,
                  enum: ["completed", "streaming", "stopped", "error"]
                },
                feedback: %Schema{type: :string, nullable: true, enum: ["like", "dislike"]},
                created_at: %Schema{type: :integer}
              },
              required: [:id, :conversation_id, :role, :content, :status, :created_at],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule Result do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "Result",
        type: :object,
        properties: %{result: %Schema{type: :string, enum: ["success"]}},
        required: [:result],
        additionalProperties: false
      })
    end

    defmodule ConversationRenamed do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ConversationRenamed",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          name: %Schema{type: :string},
          created_at: %Schema{type: :integer}
        },
        required: [:id, :name, :created_at],
        additionalProperties: false
      })
    end

    defmodule FileUpload do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "FileUpload",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          name: %Schema{type: :string},
          size: %Schema{type: :integer},
          extension: %Schema{type: :string},
          mime_type: %Schema{type: :string, nullable: true},
          created_at: %Schema{type: :integer}
        },
        required: [:id, :name, :size, :extension, :created_at],
        additionalProperties: false
      })
    end

    defmodule Meta do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "Meta",
        type: :object,
        properties: %{tool_icons: %Schema{type: :object}},
        required: [:tool_icons],
        additionalProperties: false
      })
    end
  end

  @schema_modules [
    Schemas.Error,
    Schemas.ChatMessage,
    Schemas.WorkflowRun,
    Schemas.Parameters,
    Schemas.ConversationList,
    Schemas.MessageList,
    Schemas.Result,
    Schemas.ConversationRenamed,
    Schemas.FileUpload,
    Schemas.Meta
  ]

  alias OpenApiSpex.{MediaType, Operation, PathItem, Reference, Response}

  # route → {http method, summary, response schema title}
  @operations %{
    "/chat-messages" => {:post, "Send a chat message (blocking or SSE)", "ChatMessage"},
    "/completion-messages" => {:post, "Run a completion app", "ChatMessage"},
    "/workflows/run" => {:post, "Run the token's published flux", "WorkflowRun"},
    "/workflows/runs/{id}/resume" => {:post, "Resume a paused run", "WorkflowRun"},
    "/parameters" => {:get, "App configuration for clients", "Parameters"},
    "/conversations" => {:get, "List conversations", "ConversationList"},
    "/messages" => {:get, "List a conversation's messages", "MessageList"},
    "/files/upload" => {:post, "Upload a file", "FileUpload"},
    "/meta" => {:get, "Tool metadata", "Meta"},
    "/conversations/{id}/name" => {:post, "Rename a conversation", "ConversationRenamed"},
    "/conversations/{id}" => {:delete, "Delete a conversation", "Result"},
    "/chat-messages/{id}/stop" => {:post, "Stop a streaming reply", "Result"},
    "/messages/{id}/feedbacks" => {:post, "Rate a message", "Result"}
  }

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "FluxCapacitor Service API",
        version: "1.0.0",
        description:
          "Bearer-token service API (app-… tokens for chat/completion apps, " <>
            "flux-… tokens for workflows). Wire-compatible with the upstream reference."
      },
      paths:
        for {path, {method, summary, schema_title}} <- @operations, into: %{} do
          operation = %Operation{
            summary: summary,
            operationId: operation_id(method, path),
            responses: %{
              "200" => %Response{
                description: summary,
                content: %{
                  "application/json" => %MediaType{
                    schema: %Reference{"$ref": "#/components/schemas/#{schema_title}"}
                  }
                }
              },
              "4XX" => %Response{
                description: "Error",
                content: %{
                  "application/json" => %MediaType{
                    schema: %Reference{"$ref": "#/components/schemas/Error"}
                  }
                }
              }
            }
          }

          {path, struct(PathItem, [{method, operation}])}
        end,
      components: %Components{
        schemas:
          for module <- @schema_modules, into: %{} do
            schema = module.schema()
            {schema.title, schema}
          end
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp operation_id(method, path) do
    suffix =
      path
      |> String.replace(~r/[{}]/, "")
      |> String.trim_leading("/")
      |> String.replace(["/", "-"], "_")

    "#{method}_#{suffix}"
  end
end
