defmodule Flux.Engine.Node do
  @moduledoc """
  Behaviour every node type implements.

  `run/3` receives the validated node, the variable pool (node id →
  outputs), and the host. Branching nodes return the handle the run should
  leave on; all others take their single `"default"` edge.
  """

  alias Flux.Engine.{Graph, Host}

  @callback run(Graph.Node.t(), pool :: map(), Host.t()) ::
              {:ok, outputs :: map()}
              | {:ok, outputs :: map(), branch :: String.t()}
              | {:error, term()}

  @implementations %{
    "start" => Flux.Engine.Nodes.Start,
    "llm" => Flux.Engine.Nodes.LLM,
    "if_else" => Flux.Engine.Nodes.IfElse,
    "template" => Flux.Engine.Nodes.TemplateTransform,
    "answer" => Flux.Engine.Nodes.Answer,
    "end" => Flux.Engine.Nodes.EndNode,
    "tool" => Flux.Engine.Nodes.Tool,
    "http_request" => Flux.Engine.Nodes.HttpRequest,
    "code" => Flux.Engine.Nodes.Code,
    "agent" => Flux.Engine.Nodes.Agent,
    "variable_aggregator" => Flux.Engine.Nodes.VariableAggregator,
    "variable_assigner" => Flux.Engine.Nodes.VariableAssigner,
    "list_operator" => Flux.Engine.Nodes.ListOperator,
    "question_classifier" => Flux.Engine.Nodes.QuestionClassifier,
    "parameter_extractor" => Flux.Engine.Nodes.ParameterExtractor
  }

  @doc "The module implementing a node type."
  def implementation(type), do: Map.fetch!(@implementations, type)
end
