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

    defmodule ChatCompletion do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ChatCompletion",
        description:
          "OpenAI-compatible completion (POST /v1/chat/completions, app- tokens; " <>
            "stream: true answers chat.completion.chunk SSE frames ending in [DONE])",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          object: %Schema{type: :string, enum: ["chat.completion"]},
          created: %Schema{type: :integer},
          model: %Schema{type: :string},
          choices: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                index: %Schema{type: :integer},
                message: %Schema{
                  type: :object,
                  properties: %{
                    role: %Schema{type: :string},
                    content: %Schema{type: :string}
                  }
                },
                finish_reason: %Schema{type: :string}
              }
            }
          },
          usage: %Schema{type: :object}
        },
        required: [:id, :object, :choices]
      })
    end

    defmodule EmbeddingList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "EmbeddingList",
        description: "OpenAI-compatible embeddings response (POST /v1/embeddings)",
        type: :object,
        properties: %{
          object: %Schema{type: :string, enum: ["list"]},
          model: %Schema{type: :string},
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                object: %Schema{type: :string},
                index: %Schema{type: :integer},
                embedding: %Schema{type: :array, items: %Schema{type: :number}}
              }
            }
          },
          usage: %Schema{type: :object}
        },
        required: [:object, :data]
      })
    end

    defmodule ModerationResult do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ModerationResult",
        description: "OpenAI-compatible moderation response (POST /v1/moderations)",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          model: %Schema{type: :string},
          results: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                flagged: %Schema{type: :boolean},
                categories: %Schema{type: :object},
                category_scores: %Schema{type: :object},
                reason: %Schema{type: :string, nullable: true}
              }
            }
          }
        },
        required: [:id, :results]
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
              total_tokens: %Schema{type: :integer},
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
                files: %Schema{
                  type: :array,
                  description: "Documents generated by the flux for this reply",
                  items: %Schema{
                    type: :object,
                    properties: %{
                      name: %Schema{type: :string},
                      url: %Schema{type: :string},
                      size: %Schema{type: :integer, nullable: true}
                    },
                    required: [:name, :url],
                    additionalProperties: false
                  }
                },
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

    defmodule DatasetCreated do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "DatasetCreated",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          name: %Schema{type: :string}
        },
        required: [:id, :name],
        additionalProperties: false
      })
    end

    defmodule DatasetList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "DatasetList",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                name: %Schema{type: :string},
                description: %Schema{type: :string, nullable: true},
                embedding_model: %Schema{type: :string, nullable: true},
                created_at: %Schema{type: :integer}
              },
              required: [:id, :name, :created_at],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule DocumentCreated do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "DocumentCreated",
        type: :object,
        properties: %{
          document: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              name: %Schema{type: :string},
              status: %Schema{type: :string, enum: ["pending", "indexing", "ready", "error"]}
            },
            required: [:id, :name, :status],
            additionalProperties: false
          }
        },
        required: [:document],
        additionalProperties: false
      })
    end

    defmodule DocumentList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "DocumentList",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                name: %Schema{type: :string},
                status: %Schema{type: :string, enum: ["pending", "indexing", "ready", "error"]},
                segment_count: %Schema{type: :integer},
                error: %Schema{type: :string, nullable: true},
                created_at: %Schema{type: :integer}
              },
              required: [:id, :name, :status, :segment_count, :created_at],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule SegmentList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "SegmentList",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                position: %Schema{type: :integer},
                content: %Schema{type: :string},
                enabled: %Schema{type: :boolean}
              },
              required: [:id, :position, :content, :enabled],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule RetrieveResult do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "RetrieveResult",
        type: :object,
        properties: %{
          query: %Schema{type: :string},
          records: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                segment: %Schema{
                  type: :object,
                  properties: %{
                    id: %Schema{type: :string, format: :uuid},
                    content: %Schema{type: :string},
                    position: %Schema{type: :integer}
                  },
                  required: [:id, :content, :position],
                  additionalProperties: false
                },
                document: %Schema{
                  type: :object,
                  properties: %{
                    id: %Schema{type: :string, format: :uuid},
                    name: %Schema{type: :string}
                  },
                  required: [:id, :name],
                  additionalProperties: false
                },
                score: %Schema{type: :number}
              },
              required: [:segment, :document, :score],
              additionalProperties: false
            }
          }
        },
        required: [:query, :records],
        additionalProperties: false
      })
    end

    defmodule BatchStarted do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "BatchStarted",
        description: "202 response of POST /v1/workflows/batch",
        type: :object,
        properties: %{
          batch_id: %Schema{type: :string, format: :uuid},
          status: %Schema{type: :string},
          target: %Schema{type: :string},
          total: %Schema{type: :integer}
        },
        required: [:batch_id, :status, :target, :total],
        additionalProperties: false
      })
    end

    defmodule BatchStatus do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "BatchStatus",
        type: :object,
        properties: %{
          batch_id: %Schema{type: :string, format: :uuid},
          status: %Schema{type: :string},
          target: %Schema{type: :string},
          total: %Schema{type: :integer},
          succeeded: %Schema{type: :integer},
          failed: %Schema{type: :integer},
          results: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                inputs: %Schema{type: :object},
                status: %Schema{type: :string},
                outputs: %Schema{type: :object, nullable: true},
                error: %Schema{type: :string, nullable: true}
              },
              required: [:inputs, :status],
              additionalProperties: false
            }
          }
        },
        required: [:batch_id, :status, :target, :total, :succeeded, :failed],
        additionalProperties: false
      })
    end

    defmodule EvalSetList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "EvalSetList",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                name: %Schema{type: :string},
                gate: %Schema{type: :boolean},
                schedule: %Schema{type: :string, nullable: true}
              },
              required: [:id, :name, :gate],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule EvalStarted do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "EvalStarted",
        description: "202 response of POST /v1/eval-sets/{id}/run",
        type: :object,
        properties: %{
          eval_run_id: %Schema{type: :string, format: :uuid},
          status: %Schema{type: :string},
          target: %Schema{type: :string}
        },
        required: [:eval_run_id, :status, :target],
        additionalProperties: false
      })
    end

    defmodule EvalRunStatus do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "EvalRunStatus",
        type: :object,
        properties: %{
          eval_run_id: %Schema{type: :string, format: :uuid},
          status: %Schema{type: :string},
          target: %Schema{type: :string},
          grader: %Schema{type: :string},
          total: %Schema{type: :integer},
          passed: %Schema{type: :integer},
          failed: %Schema{type: :integer},
          avg_score: %Schema{type: :number, nullable: true},
          results: %Schema{type: :array, items: %Schema{type: :object}, nullable: true}
        },
        required: [:eval_run_id, :status, :target, :grader, :total, :passed, :failed],
        additionalProperties: false
      })
    end

    defmodule LabelingProjectList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "LabelingProjectList",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                name: %Schema{type: :string},
                label_type: %Schema{type: :string, enum: ["choice", "multi", "text"]},
                options: %Schema{type: :array, items: %Schema{type: :string}},
                counts: %Schema{
                  type: :object,
                  properties: %{
                    unlabeled: %Schema{type: :integer},
                    labeled: %Schema{type: :integer},
                    skipped: %Schema{type: :integer}
                  },
                  required: [:unlabeled, :labeled, :skipped],
                  additionalProperties: false
                }
              },
              required: [:id, :name, :label_type, :options, :counts],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule LabelingTasksCreated do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "LabelingTasksCreated",
        description: "201 response of POST /v1/labeling/projects/{id}/tasks",
        type: :object,
        properties: %{
          task_ids: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}},
          count: %Schema{type: :integer}
        },
        required: [:task_ids, :count],
        additionalProperties: false
      })
    end

    defmodule LabelingNextTask do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "LabelingNextTask",
        type: :object,
        properties: %{
          task: %Schema{
            type: :object,
            nullable: true,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              data: %Schema{type: :object},
              label_type: %Schema{type: :string, enum: ["choice", "multi", "text"]},
              options: %Schema{type: :array, items: %Schema{type: :string}}
            },
            required: [:id, :data, :label_type, :options],
            additionalProperties: false
          }
        },
        required: [:task],
        additionalProperties: false
      })
    end

    defmodule ModelList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ModelList",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                name: %Schema{type: :string},
                version: %Schema{type: :integer},
                file_id: %Schema{type: :string, format: :uuid},
                file_name: %Schema{type: :string},
                metrics: %Schema{type: :object}
              },
              required: [:id, :name, :version, :file_id, :file_name, :metrics],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule DatasetArchive do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "DatasetArchive",
        description: "Portable flux-dataset/v1 archive (GET /v1/datasets/{id}/export)",
        type: :object,
        properties: %{
          format: %Schema{type: :string, enum: ["flux-dataset/v1"]},
          name: %Schema{type: :string},
          description: %Schema{type: :string, nullable: true},
          settings: %Schema{type: :object},
          documents: %Schema{type: :array, items: %Schema{type: :object}},
          retrieval_cases: %Schema{type: :array, items: %Schema{type: :object}},
          url_sources: %Schema{type: :array, items: %Schema{type: :object}}
        },
        required: [:format, :name, :settings, :documents],
        additionalProperties: false
      })
    end

    defmodule DatasetImported do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "DatasetImported",
        description: "201 response of POST /v1/datasets/import",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          name: %Schema{type: :string},
          documents: %Schema{type: :integer},
          retrieval_cases: %Schema{type: :integer},
          url_sources: %Schema{type: :integer}
        },
        required: [:id, :name, :documents],
        additionalProperties: false
      })
    end

    defmodule VisitorStatsList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "VisitorStatsList",
        description: "Per-visitor rollup for an app (GET /v1/visitors, app- tokens)",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                ref: %Schema{type: :string},
                conversations: %Schema{type: :integer},
                messages: %Schema{type: :integer},
                tokens: %Schema{type: :integer},
                likes: %Schema{type: :integer},
                dislikes: %Schema{type: :integer},
                last_seen: %Schema{type: :integer, nullable: true}
              },
              required: [:ref, :conversations, :messages, :tokens, :likes, :dislikes],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule TranscriptionResult do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "TranscriptionResult",
        description: "OpenAI-compatible POST /v1/audio/transcriptions response",
        type: :object,
        properties: %{text: %Schema{type: :string}},
        required: [:text],
        additionalProperties: false
      })
    end

    defmodule AnthropicMessage do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "AnthropicMessage",
        description: "Anthropic-compatible POST /v1/messages response (text only)",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          type: %Schema{type: :string, enum: ["message"]},
          role: %Schema{type: :string, enum: ["assistant"]},
          model: %Schema{type: :string},
          content: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                type: %Schema{type: :string, enum: ["text"]},
                text: %Schema{type: :string}
              },
              required: [:type, :text],
              additionalProperties: false
            }
          },
          stop_reason: %Schema{type: :string, nullable: true},
          stop_sequence: %Schema{type: :string, nullable: true},
          usage: %Schema{type: :object}
        },
        required: [:id, :type, :role, :content],
        additionalProperties: false
      })
    end

    defmodule RunDetail do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "RunDetail",
        description: "GET /v1/workflows/runs/{id} (?trace=true adds node_executions)",
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
          elapsed_ms: %Schema{type: :integer, nullable: true},
          usage: %Schema{type: :object, nullable: true},
          created_at: %Schema{type: :integer},
          node_executions: %Schema{type: :array, items: %Schema{type: :object}}
        },
        required: [:id, :workflow_id, :status, :created_at],
        additionalProperties: false
      })
    end

    defmodule ConversationEval do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ConversationEval",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          name: %Schema{type: :string},
          turns: %Schema{type: :integer},
          expectation: %Schema{type: :string},
          schedule: %Schema{type: :string, nullable: true},
          last_score: %Schema{type: :number, nullable: true},
          last_reason: %Schema{type: :string, nullable: true},
          last_run_at: %Schema{type: :integer, nullable: true}
        },
        required: [:id, :name, :turns, :expectation],
        additionalProperties: false
      })
    end

    defmodule ConversationEvalList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ConversationEvalList",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: ConversationEval}
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule ABStats do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ABStats",
        description: "Per-variant reply/feedback/token counts for a chat app's model A/B",
        type: :object,
        properties: %{
          split: %Schema{type: :integer},
          challenger: %Schema{type: :string, nullable: true},
          data: %Schema{
            type: :object,
            additionalProperties: %Schema{
              type: :object,
              properties: %{
                replies: %Schema{type: :integer},
                likes: %Schema{type: :integer},
                dislikes: %Schema{type: :integer},
                tokens: %Schema{type: :integer}
              },
              required: [:replies, :likes, :dislikes, :tokens],
              additionalProperties: false
            }
          }
        },
        required: [:split, :data],
        additionalProperties: false
      })
    end

    defmodule ProviderModelList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ProviderModelList",
        description: "OpenAI-compatible GET /v1/models response",
        type: :object,
        properties: %{
          object: %Schema{type: :string, enum: ["list"]},
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string},
                object: %Schema{type: :string, enum: ["model"]},
                owned_by: %Schema{type: :string}
              },
              required: [:id, :object, :owned_by],
              additionalProperties: false
            }
          }
        },
        required: [:object, :data],
        additionalProperties: false
      })
    end

    defmodule ModelRegistered do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "ModelRegistered",
        description: "201 response of POST /v1/registry/models",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          name: %Schema{type: :string},
          version: %Schema{type: :integer}
        },
        required: [:id, :name, :version],
        additionalProperties: false
      })
    end

    defmodule NotificationList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "NotificationList",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                kind: %Schema{type: :string},
                title: %Schema{type: :string},
                path: %Schema{type: :string, nullable: true},
                read: %Schema{type: :boolean},
                created_at: %Schema{type: :integer}
              },
              required: [:id, :kind, :title, :read, :created_at],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule RetrievalCaseList do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "RetrievalCaseList",
        type: :object,
        properties: %{
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                question: %Schema{type: :string},
                expected: %Schema{type: :string}
              },
              required: [:id, :question, :expected],
              additionalProperties: false
            }
          }
        },
        required: [:data],
        additionalProperties: false
      })
    end

    defmodule RetrievalCaseCreated do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "RetrievalCaseCreated",
        description: "201 response of POST /v1/datasets/{id}/retrieval-cases",
        type: :object,
        properties: %{id: %Schema{type: :string, format: :uuid}},
        required: [:id],
        additionalProperties: false
      })
    end

    defmodule RetrievalEvalResult do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "RetrievalEvalResult",
        type: :object,
        properties: %{
          total: %Schema{type: :integer},
          hits: %Schema{type: :integer},
          hit_rate: %Schema{type: :number, nullable: true},
          mrr: %Schema{type: :number, nullable: true},
          results: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                case_id: %Schema{type: :string, format: :uuid},
                question: %Schema{type: :string},
                expected: %Schema{type: :string},
                rank: %Schema{type: :integer, nullable: true}
              },
              required: [:case_id, :question, :expected],
              additionalProperties: false
            }
          }
        },
        required: [:total, :hits, :results],
        additionalProperties: false
      })
    end

    defmodule LabelingLabeled do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "LabelingLabeled",
        type: :object,
        properties: %{
          task_id: %Schema{type: :string, format: :uuid},
          status: %Schema{type: :string, enum: ["unlabeled", "labeled", "skipped"]},
          label: %Schema{type: :object, nullable: true}
        },
        required: [:task_id, :status],
        additionalProperties: false
      })
    end
  end

  @schema_modules [
    Schemas.Error,
    Schemas.ChatCompletion,
    Schemas.EmbeddingList,
    Schemas.ModerationResult,
    Schemas.ChatMessage,
    Schemas.WorkflowRun,
    Schemas.Parameters,
    Schemas.ConversationList,
    Schemas.MessageList,
    Schemas.Result,
    Schemas.ConversationRenamed,
    Schemas.FileUpload,
    Schemas.Meta,
    Schemas.DatasetCreated,
    Schemas.DatasetList,
    Schemas.DocumentCreated,
    Schemas.DocumentList,
    Schemas.SegmentList,
    Schemas.RetrieveResult,
    Schemas.BatchStarted,
    Schemas.BatchStatus,
    Schemas.EvalSetList,
    Schemas.EvalStarted,
    Schemas.EvalRunStatus,
    Schemas.LabelingProjectList,
    Schemas.LabelingTasksCreated,
    Schemas.LabelingNextTask,
    Schemas.LabelingLabeled,
    Schemas.ModelList,
    Schemas.ProviderModelList,
    Schemas.ConversationEval,
    Schemas.ConversationEvalList,
    Schemas.ABStats,
    Schemas.DatasetArchive,
    Schemas.DatasetImported,
    Schemas.VisitorStatsList,
    Schemas.TranscriptionResult,
    Schemas.AnthropicMessage,
    Schemas.RunDetail,
    Schemas.ModelRegistered,
    Schemas.NotificationList,
    Schemas.RetrievalCaseList,
    Schemas.RetrievalCaseCreated,
    Schemas.RetrievalEvalResult
  ]

  alias OpenApiSpex.{MediaType, Operation, PathItem, Reference, Response}

  # route → {http method, summary, response schema title} (or a list of
  # those tuples when several methods share the path)
  @operations %{
    "/datasets" => [
      {:get, "List datasets", "DatasetList"},
      {:post, "Create a dataset", "DatasetCreated"}
    ],
    "/datasets/{id}" => {:delete, "Delete a dataset", "Result"},
    "/datasets/{id}/document/create-by-text" => {:post, "Add a text document", "DocumentCreated"},
    "/datasets/{id}/document/create-by-url" =>
      {:post, "Fetch a URL into a document", "DocumentCreated"},
    "/datasets/{id}/documents" => {:get, "List documents", "DocumentList"},
    "/datasets/{id}/documents/{document_id}" => {:delete, "Delete a document", "Result"},
    "/datasets/{id}/documents/{document_id}/segments" =>
      {:get, "List a document's segments", "SegmentList"},
    "/datasets/{id}/retrieve" => {:post, "Retrieve matching segments", "RetrieveResult"},
    "/chat-messages" => {:post, "Send a chat message (blocking or SSE)", "ChatMessage"},
    "/chat/completions" =>
      {:post, "OpenAI-compatible chat completion (any OpenAI SDK)", "ChatCompletion"},
    "/embeddings" => {:post, "OpenAI-compatible embeddings", "EmbeddingList"},
    "/moderations" =>
      {:post, "OpenAI-compatible moderation via workspace guardrails", "ModerationResult"},
    "/completion-messages" => {:post, "Run a completion app", "ChatMessage"},
    "/workflows/run" => {:post, "Run the token's published flux", "WorkflowRun"},
    "/workflows/runs/{id}/resume" => {:post, "Resume a paused run", "WorkflowRun"},
    "/parameters" => {:get, "App configuration for clients", "Parameters"},
    "/conversations" => {:get, "List conversations", "ConversationList"},
    "/messages" => [
      {:get, "List a conversation's messages", "MessageList"},
      {:post, "Anthropic-compatible completion (app- tokens)", "AnthropicMessage"}
    ],
    "/files/upload" => {:post, "Upload a file", "FileUpload"},
    "/meta" => {:get, "Tool metadata", "Meta"},
    "/conversations/{id}/name" => {:post, "Rename a conversation", "ConversationRenamed"},
    "/conversations/{id}" => {:delete, "Delete a conversation", "Result"},
    "/chat-messages/{id}/stop" => {:post, "Stop a streaming reply", "Result"},
    "/messages/{id}/feedbacks" => {:post, "Rate a message", "Result"},
    "/workflows/batch" => {:post, "Start a batch over input rows", "BatchStarted", 202},
    "/batches/{id}" => {:get, "Batch progress (optionally with results)", "BatchStatus"},
    "/eval-sets" => {:get, "List the flux's eval sets", "EvalSetList"},
    "/eval-sets/{id}/run" => {:post, "Start an eval run", "EvalStarted", 202},
    "/eval-runs/{id}" => {:get, "Eval run status and results", "EvalRunStatus"},
    "/labeling/projects" => {:get, "List labeling projects", "LabelingProjectList"},
    "/labeling/projects/{id}/tasks" =>
      {:post, "Push items as labeling tasks", "LabelingTasksCreated", 201},
    "/labeling/projects/{id}/next" => {:get, "Claim the next unlabeled task", "LabelingNextTask"},
    "/labeling/tasks/{id}/label" => {:post, "Submit a label", "LabelingLabeled"},
    "/models" => {:get, "OpenAI-compatible provider model list", "ProviderModelList"},
    "/registry/models" => [
      {:get, "List registered models", "ModelList"},
      {:post, "Register a stored file as a model", "ModelRegistered", 201}
    ],
    "/notifications" => {:get, "Workspace notification feed", "NotificationList"},
    "/audio/transcriptions" =>
      {:post, "OpenAI-compatible speech-to-text (multipart file)", "TranscriptionResult"},
    "/workflows/runs/{id}" => {:get, "Run status (?trace=true adds nodes)", "RunDetail"},
    "/workflows/runs/{id}/stop" => {:post, "Stop a running run", "RunDetail"},
    "/conversation-evals" => {:get, "List the app's conversation evals", "ConversationEvalList"},
    "/conversation-evals/{id}/run" =>
      {:post, "Replay and judge a scripted dialogue (blocking)", "ConversationEval"},
    "/ab-stats" => {:get, "Model A/B per-variant stats", "ABStats"},
    "/visitors" => {:get, "Per-visitor rollup (app- tokens)", "VisitorStatsList"},
    "/datasets/{id}/retrieval-cases" => [
      {:get, "List golden retrieval cases", "RetrievalCaseList"},
      {:post, "Add a golden retrieval case", "RetrievalCaseCreated", 201}
    ],
    "/datasets/{id}/retrieval-eval" =>
      {:post, "Score retrieval (hit rate + MRR)", "RetrievalEvalResult"},
    "/datasets/{id}/export" => {:get, "Portable dataset archive", "DatasetArchive"},
    "/datasets/import" => {:post, "Rebuild a dataset from an archive", "DatasetImported", 201}
  }

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "FluxCapacitor Service API",
        version: "1.0.0",
        description:
          "Bearer-token service API (app-… tokens for chat/completion apps, " <>
            "flux-… tokens for workflows, ws-… tokens for workspace-level " <>
            "endpoints). Wire-compatible with the upstream reference. " <>
            "Beyond /v1: POST /mcp speaks Model Context Protocol with a ws- " <>
            "token; POST /triggers/webhook/{token} starts a published flux " <>
            "from any outside system."
      },
      paths:
        for {path, methods} <- @operations, into: %{} do
          entries =
            for entry <- List.wrap(methods) do
              {method, summary, schema_title, status} =
                case entry do
                  {method, summary, schema_title} -> {method, summary, schema_title, 200}
                  {_method, _summary, _schema_title, _status} = full -> full
                end

              {method, operation(method, path, summary, schema_title, status)}
            end

          {path, struct(PathItem, entries)}
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

  defp operation(method, path, summary, schema_title, status) do
    %Operation{
      summary: summary,
      operationId: operation_id(method, path),
      responses: %{
        to_string(status) => %Response{
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
