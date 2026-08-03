defmodule Flux.Workflows.Templates do
  @moduledoc """
  Starter flux templates for "New from template": engine-valid graphs a
  new workspace can run (or wire up) in minutes. Every graph here must
  pass `Flux.Engine.build/1` — a test enforces it.
  """

  def all do
    [
      %{
        id: "triage",
        name: "Branching triage",
        description: "Route bug reports and questions down different prompts, then answer.",
        graph: triage()
      },
      %{
        id: "rag_answer",
        name: "RAG answer",
        description:
          "Retrieve from a knowledge dataset and answer with citations — wire a dataset in.",
        graph: rag_answer()
      },
      %{
        id: "human_review",
        name: "Human-reviewed reply",
        description:
          "Draft with a model, pause for a human label/correction, ship the human's version.",
        graph: human_review()
      },
      %{
        id: "model_trainer",
        name: "Model trainer",
        description:
          "Paste a labeling JSONL export, train a scikit-learn classifier in the sandbox, " <>
            "and keep the model as a run artifact.",
        graph: model_trainer()
      }
    ]
  end

  def get(id) do
    case Enum.find(all(), &(&1.id == id)) do
      nil -> nil
      template -> %{template | graph: layout(template.graph)}
    end
  end

  # Canvas positions so templates land readable, not stacked at 0,0.
  defp layout(graph) do
    nodes =
      graph["nodes"]
      |> Enum.with_index()
      |> Enum.map(fn {node, index} ->
        Map.put_new(node, "position", %{
          "x" => 80 + index * 280,
          "y" => 140 + rem(index, 2) * 170
        })
      end)

    %{graph | "nodes" => nodes}
  end

  defp triage do
    %{
      "nodes" => [
        start_node([
          %{"name" => "query", "label" => "Message", "type" => "paragraph", "required" => true}
        ]),
        node("route", "if_else", "Bug or not?", %{
          "logical_operator" => "and",
          "conditions" => [
            %{"left" => "{{start.query}}", "operator" => "contains", "right" => "bug"}
          ]
        }),
        node("bug_reply", "llm", "Bug reply", %{
          "prompt" =>
            "A user reported a bug: {{start.query}}\n" <>
              "Acknowledge it, ask for reproduction steps, and be brief."
        }),
        node("general_reply", "llm", "General reply", %{
          "prompt" => "Answer helpfully and briefly: {{start.query}}"
        }),
        node("answer_bug", "answer", "Answer", %{"answer" => "{{bug_reply.text}}"}),
        node("answer_general", "answer", "Answer", %{"answer" => "{{general_reply.text}}"})
      ],
      "edges" => [
        edge("e1", "start", "route"),
        edge("e2", "route", "bug_reply", "true"),
        edge("e3", "route", "general_reply", "false"),
        edge("e4", "bug_reply", "answer_bug"),
        edge("e5", "general_reply", "answer_general")
      ]
    }
  end

  defp rag_answer do
    %{
      "nodes" => [
        start_node([
          %{
            "name" => "question",
            "label" => "Question",
            "type" => "paragraph",
            "required" => true
          }
        ]),
        node("retrieve", "knowledge_retrieval", "Retrieve", %{
          "dataset_ids" => [],
          "query" => "{{start.question}}"
        }),
        node("compose", "llm", "Compose", %{
          "prompt" =>
            "Answer the question using only this context.\n\n" <>
              "Context:\n{{retrieve.result}}\n\nQuestion: {{start.question}}"
        }),
        node("answer", "answer", "Answer", %{"answer" => "{{compose.text}}"})
      ],
      "edges" => [
        edge("e1", "start", "retrieve"),
        edge("e2", "retrieve", "compose"),
        edge("e3", "compose", "answer")
      ]
    }
  end

  defp human_review do
    %{
      "nodes" => [
        start_node([
          %{
            "name" => "question",
            "label" => "Question",
            "type" => "paragraph",
            "required" => true
          }
        ]),
        node("draft", "llm", "Draft", %{
          "prompt" => "Draft a reply to: {{start.question}}"
        }),
        node("review", "labeling", "Human review", %{
          "project_id" => "",
          "data" => [
            %{"name" => "question", "value" => "{{start.question}}"},
            %{"name" => "answer", "value" => "{{draft.text}}"}
          ]
        }),
        node("answer", "answer", "Answer", %{"answer" => "{{review.text}}"})
      ],
      "edges" => [
        edge("e1", "start", "draft"),
        edge("e2", "draft", "review"),
        edge("e3", "review", "answer")
      ]
    }
  end

  defp model_trainer do
    code = """
    import json
    import joblib
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import make_pipeline

    def main(labeled_jsonl):
        rows = [json.loads(line) for line in labeled_jsonl.splitlines() if line.strip()]
        texts = [json.dumps(row["data"], sort_keys=True) for row in rows]
        labels = [row["label"].get("choice") or row["label"].get("text") for row in rows]
        model = make_pipeline(TfidfVectorizer(), LogisticRegression(max_iter=1000))
        model.fit(texts, labels)
        joblib.dump(model, "artifacts/model.joblib")
        return {
            "trained_on": len(rows),
            "classes": sorted(set(labels)),
            "train_accuracy": round(float(model.score(texts, labels)), 4),
        }
    """

    %{
      "nodes" => [
        start_node([
          %{
            "name" => "labeled_jsonl",
            "label" => "Labeled JSONL (from a labeling project export)",
            "type" => "paragraph",
            "required" => true
          }
        ]),
        node("train", "code", "Train classifier", %{
          "language" => "python3",
          "code" => code,
          "dependencies" => [%{"name" => "joblib", "version" => ""}],
          "inputs" => [%{"name" => "labeled_jsonl", "value" => "{{start.labeled_jsonl}}"}]
        }),
        node("answer", "answer", "Answer", %{
          "answer" =>
            "Trained on {{train.trained_on}} examples " <>
              "(train accuracy {{train.train_accuracy}}). " <>
              "The model artifact is attached to this run — reuse its file id " <>
              "as a code-node attachment to serve predictions."
        })
      ],
      "edges" => [
        edge("e1", "start", "train"),
        edge("e2", "train", "answer")
      ]
    }
  end

  defp start_node(variables) do
    %{
      "id" => "start",
      "type" => "start",
      "title" => "Start",
      "position" => %{"x" => 80, "y" => 160},
      "config" => %{"variables" => variables}
    }
  end

  defp node(id, type, title, config) do
    %{"id" => id, "type" => type, "title" => title, "config" => config}
  end

  defp edge(id, source, target, handle \\ "default") do
    %{"id" => id, "source" => source, "source_handle" => handle, "target" => target}
  end
end
