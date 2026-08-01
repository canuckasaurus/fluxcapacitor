defmodule Flux.Demo do
  @moduledoc """
  Seeds a showcase workspace (`mix flux.demo`): example fluxes, a
  knowledge base, and published apps — everything runs end-to-end on the
  keyless echo provider, so the platform is demoable with zero external
  credentials. Refuses to run twice.
  """

  alias Flux.Accounts

  @email "demo@fluxcapacitor.local"

  def email, do: @email

  def seed do
    if Accounts.get_account_by_email(@email) do
      {:error, :already_seeded}
    else
      {:ok, account} = Accounts.get_or_register_sso_account(@email)

      {:ok, {workspace, _membership}} =
        Accounts.create_workspace(account, %{name: "Demo Workspace"})

      scope = Accounts.scope_for(account)

      :ok = Flux.Tools.install_plugin(scope, "utility")
      :ok = Flux.Tools.install_plugin(scope, "rss")

      dataset = seed_knowledge(scope)
      triage = seed_triage_flux(scope)
      qa_flux = seed_qa_flux(scope, dataset)
      agent_flux = seed_agent_flux(scope)
      apps = seed_apps(scope, qa_flux)

      {:ok,
       %{
         account: account,
         workspace: workspace,
         dataset: dataset,
         fluxes: [triage, qa_flux, agent_flux],
         apps: apps
       }}
    end
  end

  defp seed_knowledge(scope) do
    rag = Application.get_env(:flux, :rag_module, Flux.RAG)

    {:ok, dataset} =
      rag.create_dataset(scope, %{
        "name" => "Product Handbook",
        "description" => "Policies the demo assistant answers from.",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    documents = [
      {"refunds.md",
       "Refund policy: purchases are refundable within 30 days of delivery. " <>
         "Refunds arrive on the original payment method within 5 business days."},
      {"shipping.md",
       "Shipping policy: standard shipping takes 3 to 5 business days. " <>
         "Express shipping is next-day for orders placed before noon."},
      {"warranty.md",
       "Warranty: every device carries a two-year limited warranty covering " <>
         "manufacturing defects. Water damage is not covered."}
    ]

    for {name, content} <- documents do
      {:ok, document} = rag.add_document(scope, dataset, %{name: name, content: content})
      # Index inline so the demo retrieves instantly (idempotent with Oban).
      rag.index_document(document.id)
    end

    dataset
  end

  defp seed_triage_flux(scope) do
    {:ok, workflow} =
      Flux.Workflows.create_workflow(scope, %{
        "name" => "Support Triage",
        "description" => "Routes refund questions differently from everything else."
      })

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 120},
          "config" => %{
            "variables" => [
              %{"name" => "query", "label" => "Question", "type" => "text", "required" => true}
            ]
          }
        },
        %{
          "id" => "route",
          "type" => "if_else",
          "title" => "Refund?",
          "position" => %{"x" => 280, "y" => 120},
          "config" => %{
            "logical_operator" => "or",
            "conditions" => [
              %{"left" => "{{start.query}}", "operator" => "contains", "right" => "refund"},
              %{"left" => "{{start.query}}", "operator" => "contains", "right" => "money back"}
            ]
          }
        },
        %{
          "id" => "refunds",
          "type" => "llm",
          "title" => "Refund desk",
          "position" => %{"x" => 560, "y" => 20},
          "config" => %{
            "provider_plugin_id" => "echo",
            "model" => "echo-1",
            "system_prompt" => "You are the refunds specialist.",
            "prompt" => "Refund question: {{start.query}}"
          }
        },
        %{
          "id" => "general",
          "type" => "llm",
          "title" => "General desk",
          "position" => %{"x" => 560, "y" => 220},
          "config" => %{
            "provider_plugin_id" => "echo",
            "model" => "echo-1",
            "prompt" => "General question: {{start.query}}"
          }
        },
        %{
          "id" => "merge",
          "type" => "variable_aggregator",
          "title" => "Answer",
          "position" => %{"x" => 840, "y" => 120},
          "config" => %{"variables" => ["refunds.text", "general.text"]}
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Reply",
          "position" => %{"x" => 1120, "y" => 120},
          "config" => %{"answer" => "{{merge.output}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "route"},
        %{"id" => "e2", "source" => "route", "source_handle" => "true", "target" => "refunds"},
        %{"id" => "e3", "source" => "route", "source_handle" => "false", "target" => "general"},
        %{"id" => "e4", "source" => "refunds", "source_handle" => "default", "target" => "merge"},
        %{"id" => "e5", "source" => "general", "source_handle" => "default", "target" => "merge"},
        %{"id" => "e6", "source" => "merge", "source_handle" => "default", "target" => "answer_1"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, _version} = Flux.Workflows.publish(scope, workflow)
    {:ok, workflow} = Flux.Workflows.enable_site(scope, workflow)
    workflow
  end

  defp seed_qa_flux(scope, dataset) do
    {:ok, workflow} =
      Flux.Workflows.create_workflow(scope, %{
        "name" => "Handbook Q&A",
        "description" => "Retrieves from the Product Handbook and answers with citations."
      })

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 100},
          "config" => %{"variables" => []}
        },
        %{
          "id" => "kb",
          "type" => "knowledge_retrieval",
          "title" => "Handbook",
          "position" => %{"x" => 280, "y" => 100},
          "config" => %{"dataset_ids" => [dataset.id], "query" => "{{sys.query}}", "top_k" => 2}
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Answer",
          "position" => %{"x" => 560, "y" => 100},
          "config" => %{"answer" => "From the handbook: {{kb.result}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "kb"},
        %{"id" => "e2", "source" => "kb", "source_handle" => "default", "target" => "answer_1"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, _version} = Flux.Workflows.publish(scope, workflow)
    workflow
  end

  defp seed_agent_flux(scope) do
    {:ok, workflow} =
      Flux.Workflows.create_workflow(scope, %{
        "name" => "Agent Scratchpad",
        "description" => "An agent with a private drive it can write notes to."
      })

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 100},
          "config" => %{
            "variables" => [
              %{"name" => "query", "label" => "Task", "type" => "text", "required" => true}
            ]
          }
        },
        %{
          "id" => "agent_1",
          "type" => "agent",
          "title" => "Agent",
          "position" => %{"x" => 280, "y" => 100},
          "config" => %{
            "provider_plugin_id" => "echo",
            "model" => "echo-1",
            "instructions" => "Work through the task; keep notes on your drive.",
            "query" => "{{start.query}}",
            "max_iterations" => 5,
            "enable_drive" => true,
            "tools" => []
          }
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Result",
          "position" => %{"x" => 560, "y" => 100},
          "config" => %{"answer" => "{{agent_1.text}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "agent_1"},
        %{
          "id" => "e2",
          "source" => "agent_1",
          "source_handle" => "default",
          "target" => "answer_1"
        }
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, _version} = Flux.Workflows.publish(scope, workflow)
    workflow
  end

  defp seed_apps(scope, qa_flux) do
    {:ok, support} =
      Flux.Chat.create_app(scope, %{
        "name" => "Support Echo",
        "description" => "A chat app on the keyless echo provider.",
        "provider_plugin_id" => "echo",
        "model" => "echo-1",
        "system_prompt" => "You are a friendly demo assistant.",
        "opening_statement" => "Hi! I'm the demo assistant — ask me anything.",
        "suggested_questions" => ["What can you do?", "How do refunds work?"]
      })

    {:ok, support} = Flux.Chat.enable_site(scope, support)

    {:ok, assistant} =
      Flux.Chat.create_app(scope, %{
        "name" => "Handbook Assistant",
        "description" => "Chatflow answering from the Product Handbook with citations.",
        "mode" => "advanced_chat",
        "workflow_id" => qa_flux.id
      })

    {:ok, summarizer} =
      Flux.Chat.create_app(scope, %{
        "name" => "Summarizer",
        "description" => "A completion app built from a prompt template.",
        "mode" => "completion",
        "provider_plugin_id" => "echo",
        "model" => "echo-1",
        "prompt_template" => "Summarize in one sentence: {{inputs.text}}",
        "input_form" => [
          %{"variable" => "text", "label" => "Text", "type" => "paragraph", "required" => true}
        ]
      })

    [support, assistant, summarizer]
  end
end
