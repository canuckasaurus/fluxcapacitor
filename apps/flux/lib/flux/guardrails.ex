defmodule Flux.Guardrails do
  @moduledoc """
  Workspace guardrails: deny patterns (case-insensitive regex, one per
  line in settings) checked against run/chat inputs and outputs. The
  configured action decides input handling — `block` refuses with an
  honest error, `flag` lets it through — and every violation lands a
  `guardrail` notification (routable to webhooks like any other kind).
  Outputs are always flag-only: the tokens are already spent, so the
  team gets told rather than the user getting a hole in the reply.
  """

  alias Flux.Accounts.Scope
  alias Flux.Accounts.Workspace
  alias Flux.Repo

  @doc "The workspace's guardrail config: `%{patterns: [...], action: \"block\"|\"flag\"}`."
  def config(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %{custom_config: %{"guardrails" => %{"patterns" => patterns} = config}}
      when is_list(patterns) and patterns != [] ->
        %{patterns: patterns, action: config["action"] || "block"}

      _off ->
        nil
    end
  end

  @doc "Saves patterns (newline-separated; blank disables) and the action."
  def configure(%Scope{} = scope, patterns_text, action)
      when action in ["block", "flag", "redact"] do
    patterns =
      patterns_text
      |> to_string()
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    invalid = Enum.find(patterns, &match?({:error, _reason}, Regex.compile(&1, "i")))

    cond do
      invalid != nil ->
        {:error, {:invalid_pattern, invalid}}

      patterns == [] ->
        update(scope, nil)

      true ->
        update(scope, %{"patterns" => patterns, "action" => action})
    end
  end

  defp update(scope, value), do: update_key(scope, "guardrails", value)

  defp update_key(scope, key, value) do
    with :ok <- Flux.RBAC.authorize(scope, :customization_manage),
         %Workspace{} = workspace <- Repo.get(Workspace, Scope.workspace_id(scope)) do
      custom_config =
        if value == nil do
          Map.delete(workspace.custom_config || %{}, key)
        else
          Map.put(workspace.custom_config || %{}, key, value)
        end

      workspace |> Ecto.Changeset.change(custom_config: custom_config) |> Repo.update()
    end
  end

  ## Model-backed moderation (opt-in, judged by the workspace default model)

  @doc "The moderation config: `%{policy: text, action: \"block\"|\"flag\"}` or nil."
  def moderation_config(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %{custom_config: %{"moderation" => %{"policy" => policy} = config}}
      when is_binary(policy) and policy != "" ->
        %{policy: policy, action: config["action"] || "block"}

      _off ->
        nil
    end
  end

  @doc "Saves the moderation policy (blank disables) and action."
  def configure_moderation(%Scope{} = scope, policy, action) when action in ["block", "flag"] do
    case String.trim(to_string(policy)) do
      "" -> update_key(scope, "moderation", nil)
      policy -> update_key(scope, "moderation", %{"policy" => policy, "action" => action})
    end
  end

  # `{:deny, reason}` when the judge refuses the text, :ok otherwise.
  # Judge failures allow — moderation must not take the product down.
  defp moderation_verdict(workspace_id, text) do
    case moderation_config(workspace_id) do
      nil ->
        :ok

      %{policy: policy} ->
        judge =
          Application.get_env(:flux, :moderation_judge) ||
            (&default_moderation_judge/2)

        case judge.(workspace_id, moderation_prompt(policy, text)) do
          "DENY" <> rest -> {:deny, String.trim(String.trim_leading(rest, ":"))}
          _allow_or_error -> :ok
        end
    end
  end

  defp default_moderation_judge(workspace_id, prompt) do
    case Flux.Workflows.invoke_default_llm_for_workspace(workspace_id, [
           %{role: :user, content: prompt}
         ]) do
      {:ok, content} when is_binary(content) -> String.trim(content)
      _error_or_no_model -> "ALLOW"
    end
  end

  defp moderation_prompt(policy, text) do
    """
    You are a content moderator. Policy:

    #{policy}

    Judge the following content against the policy. Reply with exactly
    ALLOW, or DENY: <short reason>. Nothing else.

    Content:
    #{String.slice(text, 0, 8_000)}
    """
  end

  @doc "First matching pattern in the text, or nil."
  def violation(workspace_id, text) when is_binary(text) do
    case config(workspace_id) do
      nil ->
        nil

      %{patterns: patterns} ->
        Enum.find(patterns, fn pattern ->
          case Regex.compile(pattern, "i") do
            {:ok, regex} -> Regex.match?(regex, text)
            {:error, _reason} -> false
          end
        end)
    end
  end

  def violation(_workspace_id, _text), do: nil

  @doc """
  Input gate: `:ok`, or `{:error, :guardrail}` when a pattern matches
  and the action is block. Either way a violation notifies the team.
  """
  def check_input(workspace_id, text, context \\ "input") do
    case sanitize_input(workspace_id, text, context) do
      {:ok, _text} -> :ok
      {:error, :guardrail} -> {:error, :guardrail}
    end
  end

  @doc """
  Like `check_input/3` but returns the text to actually use: with the
  `redact` action, matched patterns are masked (`•••`) before the model
  ever sees them — PII protection that doesn't refuse the message.
  """
  def sanitize_input(workspace_id, text, context \\ "input") do
    case violation(workspace_id, text) do
      nil ->
        with :ok <- check_input_moderation(workspace_id, text, context), do: {:ok, text}

      pattern ->
        notify(workspace_id, pattern, context)

        case config(workspace_id) do
          %{action: "flag"} ->
            with :ok <- check_input_moderation(workspace_id, text, context), do: {:ok, text}

          %{action: "redact"} ->
            redacted = redact_text(workspace_id, text)

            with :ok <- check_input_moderation(workspace_id, redacted, context),
                 do: {:ok, redacted}

          _block ->
            {:error, :guardrail}
        end
    end
  end

  @doc "Masks every configured pattern's matches in the text."
  def redact_text(workspace_id, text) do
    case config(workspace_id) do
      nil ->
        text

      %{patterns: patterns} ->
        Enum.reduce(patterns, text, fn pattern, acc ->
          case Regex.compile(pattern, "i") do
            {:ok, regex} -> Regex.replace(regex, acc, "•••")
            {:error, _reason} -> acc
          end
        end)
    end
  end

  @doc "Redact-mode masks string values in a run's inputs map; other modes pass through."
  def maybe_redact_inputs(workspace_id, inputs) when is_map(inputs) do
    case config(workspace_id) do
      %{action: "redact"} ->
        Map.new(inputs, fn
          {key, value} when is_binary(value) -> {key, redact_text(workspace_id, value)}
          pair -> pair
        end)

      _other ->
        inputs
    end
  end

  @doc """
  Output text to store/show: redact-mode masks matches (and notifies);
  other modes return the text untouched (`flag_output/3` still tells
  the team).
  """
  def sanitize_output(workspace_id, text, context \\ "output") do
    case {config(workspace_id), violation(workspace_id, text)} do
      {%{action: "redact"}, pattern} when pattern != nil ->
        notify(workspace_id, pattern, context)
        redact_text(workspace_id, text)

      _other ->
        flag_output(workspace_id, text, context)
        text
    end
  end

  defp check_input_moderation(workspace_id, text, context) do
    case moderation_verdict(workspace_id, text) do
      :ok ->
        :ok

      {:deny, reason} ->
        notify(workspace_id, "moderation: #{reason}", context)

        case moderation_config(workspace_id) do
          %{action: "flag"} -> :ok
          _block -> {:error, :guardrail}
        end
    end
  end

  @doc "Output check: never blocks, always notifies on a match."
  def flag_output(workspace_id, text, context \\ "output") do
    case violation(workspace_id, text) do
      nil -> :ok
      pattern -> notify(workspace_id, pattern, context)
    end

    case moderation_verdict(workspace_id, text) do
      :ok -> :ok
      {:deny, reason} -> notify(workspace_id, "moderation: #{reason}", context)
    end
  end

  @doc """
  Standalone verdict for the compat `/v1/moderations` endpoint: checks
  the text against both the pattern guardrails and the LLM moderation
  policy without notifying or blocking anything. Returns
  `%{flagged: bool, pattern: matched | nil, policy_reason: reason | nil}`.
  """
  def review(workspace_id, text) when is_binary(text) do
    pattern = violation(workspace_id, text)

    policy_reason =
      case moderation_verdict(workspace_id, text) do
        {:deny, reason} -> reason
        :ok -> nil
      end

    %{
      flagged: pattern != nil or policy_reason != nil,
      pattern: pattern,
      policy_reason: policy_reason
    }
  end

  defp notify(workspace_id, pattern, context) do
    Flux.Notifications.notify(
      workspace_id,
      "guardrail",
      "Guardrail matched on #{context}: pattern #{inspect(pattern)}",
      "/console/settings"
    )
  end
end
