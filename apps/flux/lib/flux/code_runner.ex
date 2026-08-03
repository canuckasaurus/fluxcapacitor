defmodule Flux.CodeRunner do
  @moduledoc """
  Executes workflow code blocks. Spec:
  `%{language, code, dependencies, inputs, timeout_ms}` →
  `{:ok, %{result: map, stdout: binary, artifacts: [%{name, binary}]}}`
  or `{:error, message}`.

  Two file lanes close the train→serve loop:

    * **attachments** (`spec[:attachments]`, `[%{"file_id" => id}]`) —
      workspace run-output files fetched from storage and placed next to
      the user code before it runs (e.g. a previously trained model).
    * **artifacts** — files the code saves under `./artifacts/` come
      back as binaries; the code node stores them as run-output files.

  Backends (`config :flux, :code_runner`):

    * `Flux.CodeRunner.Sandbox` — HTTP to the flux-coderunner service
      (production; multi-language, uv/Deno-backed dependency caching)
    * `Flux.CodeRunner.Local` — direct subprocess, python3 only, no
      isolation; dev-only and off unless explicitly enabled
    * `Flux.FakeCodeRunner` — test double (test/support)
  """

  @type spec :: %{
          language: String.t(),
          code: String.t(),
          dependencies: [map()],
          inputs: map(),
          timeout_ms: pos_integer()
        }

  @callback run(spec()) ::
              {:ok, %{result: map(), stdout: String.t()}} | {:error, String.t()}

  @max_attachments 5
  @max_attachment_bytes 20 * 1024 * 1024

  def run(spec, workspace_id \\ nil) do
    case resolve_attachments(spec, workspace_id) do
      {:ok, spec} -> impl().run(spec)
      {:error, message} -> {:error, message}
    end
  end

  # Attachment file ids resolve to workspace-owned run-output files; the
  # backend receives them as `files` (name + base64 content).
  defp resolve_attachments(spec, workspace_id) do
    attachments = spec |> Map.get(:attachments) |> List.wrap()

    cond do
      attachments == [] ->
        {:ok, Map.delete(spec, :attachments)}

      workspace_id == nil ->
        {:error, "attachments are not available in this execution context"}

      length(attachments) > @max_attachments ->
        {:error, "too many attachments (max #{@max_attachments})"}

      true ->
        fetch_attachments(spec, attachments, workspace_id)
    end
  end

  defp fetch_attachments(spec, attachments, workspace_id) do
    fetched =
      Enum.reduce_while(attachments, {[], 0}, fn attachment, {files, total} ->
        file_id = to_string(attachment["file_id"] || attachment[:file_id] || "")
        file_id = resolve_registry_ref(file_id, workspace_id)

        with {:ok, _uuid} <- Ecto.UUID.cast(file_id),
             %Flux.Chat.UploadedFile{workspace_id: ^workspace_id} = file <-
               Flux.Repo.get(Flux.Chat.UploadedFile, file_id, skip_workspace_guard: true),
             {:ok, binary} <- Flux.Storage.get(file.key),
             total = total + byte_size(binary),
             true <- total <= @max_attachment_bytes || :too_large do
          name = to_string(attachment["name"] || attachment[:name] || file.name)
          {:cont, {[%{"name" => name, "content_b64" => Base.encode64(binary)} | files], total}}
        else
          :too_large ->
            {:halt, {:error, "attachments exceed #{div(@max_attachment_bytes, 1_048_576)} MB"}}

          _missing ->
            {:halt, {:error, "attachment #{file_id} was not found in this workspace"}}
        end
      end)

    case fetched do
      {:error, message} ->
        {:error, message}

      {files, _total} ->
        {:ok, spec |> Map.delete(:attachments) |> Map.put(:files, Enum.reverse(files))}
    end
  end

  # "registry:name" resolves to the LATEST registered version of that
  # model at run time — promote a new version and every serving flux
  # picks it up without edits. Unknown names fall through untouched (the
  # UUID cast produces the honest not-found error).
  defp resolve_registry_ref("registry:" <> name, workspace_id) do
    import Ecto.Query

    latest =
      Flux.Registry.ModelArtifact
      |> where([m], m.workspace_id == ^workspace_id and m.name == ^String.trim(name))
      |> order_by([m], desc: m.version)
      |> limit(1)
      |> Flux.Repo.one(skip_workspace_guard: true)

    (latest && latest.file_id) || "registry:" <> name
  end

  defp resolve_registry_ref(file_id, _workspace_id), do: file_id

  defp impl, do: Application.get_env(:flux, :code_runner, Flux.CodeRunner.Sandbox)
end

defmodule Flux.CodeRunner.Sandbox do
  @moduledoc """
  HTTP client for the flux-coderunner service (internal network only;
  `CODE_RUNNER_URL` + `CODE_RUNNER_API_KEY`).
  """
  @behaviour Flux.CodeRunner

  @impl true
  def run(spec) do
    config = Application.get_env(:flux, __MODULE__, [])

    case config[:url] do
      url when is_binary(url) and url != "" ->
        request(url, config[:api_key], spec)

      _unset ->
        {:error, "No code runner is configured (set CODE_RUNNER_URL)."}
    end
  end

  defp request(url, api_key, spec) do
    options =
      [
        url: String.trim_trailing(url, "/") <> "/run",
        json: spec,
        headers: auth(api_key),
        receive_timeout: spec.timeout_ms + :timer.seconds(30),
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:flux, :code_runner_req_options, []))

    case Req.post(options) do
      {:ok, %{status: 200, body: %{"result" => %{} = result} = body}} ->
        {:ok,
         %{
           result: result,
           stdout: body["stdout"] || "",
           artifacts: decode_artifacts(body["artifacts"])
         }}

      {:ok, %{status: 200, body: body}} ->
        {:error, body["error"] || "the code block's main() must return a dict/object"}

      {:ok, %{status: 422, body: body}} when is_map(body) ->
        {:error, body["error"] || "code execution failed"}

      {:ok, %{status: status}} ->
        {:error, "code runner returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "could not reach the code runner: #{inspect(reason)}"}
    end
  end

  defp auth(nil), do: []
  defp auth(key), do: [{"authorization", "Bearer #{key}"}]

  defp decode_artifacts(artifacts) do
    for %{"name" => name, "content_b64" => encoded} <- List.wrap(artifacts),
        {:ok, binary} <- [Base.decode64(encoded)] do
      %{name: name, binary: binary}
    end
  end
end

defmodule Flux.CodeRunner.Local do
  @moduledoc """
  Dev-only python3 execution as a plain subprocess — NO sandboxing, NO
  dependency installation (uses whatever the local interpreter has).
  Disabled unless `config :flux, Flux.CodeRunner.Local, enabled: true`.
  """
  @behaviour Flux.CodeRunner

  @wrapper """
  import json, sys, io, contextlib
  sys.path.insert(0, ".")
  import usercode
  with open("inputs.json", "r", encoding="utf-8") as f:
      inputs = json.load(f)
  buffer = io.StringIO()
  with contextlib.redirect_stdout(buffer):
      result = usercode.main(**inputs)
  if not isinstance(result, dict):
      print("__FLUX_NOT_DICT__", file=sys.stderr)
      sys.exit(3)
  with open("__result__.json", "w", encoding="utf-8") as f:
      json.dump(result, f)
  sys.stderr.write(buffer.getvalue())
  """

  @impl true
  def run(%{language: "python3"} = spec) do
    if enabled?() do
      execute(spec)
    else
      {:error, "The local code runner is disabled (dev-only; enable Flux.CodeRunner.Local)."}
    end
  end

  def run(%{language: language}) do
    {:error, "The local runner only supports python3 (got #{language})."}
  end

  defp execute(spec) do
    with {:ok, python} <- find_python() do
      dir = Path.join(System.tmp_dir!(), "flux-code-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        File.write!(Path.join(dir, "usercode.py"), spec.code)
        File.write!(Path.join(dir, "inputs.json"), Jason.encode!(spec.inputs))
        File.write!(Path.join(dir, "wrapper.py"), @wrapper)
        File.mkdir_p!(Path.join(dir, "artifacts"))

        for %{"name" => name, "content_b64" => encoded} <- Map.get(spec, :files, []) do
          File.write!(Path.join(dir, Path.basename(name)), Base.decode64!(encoded))
        end

        task =
          Task.async(fn ->
            System.cmd(python, ["wrapper.py"], cd: dir, stderr_to_stdout: true)
          end)

        case Task.yield(task, spec.timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            result = dir |> Path.join("__result__.json") |> File.read!() |> Jason.decode!()
            {:ok, %{result: result, stdout: output, artifacts: collect_artifacts(dir)}}

          {:ok, {output, 3}} ->
            {:error, "main() must return a dict (stderr: #{String.slice(output, 0, 500)})"}

          {:ok, {output, code}} ->
            {:error, "exit #{code}: #{String.slice(output, 0, 500)}"}

          nil ->
            {:error, "code execution timed out after #{spec.timeout_ms} ms"}
        end
      after
        File.rm_rf(dir)
      end
    end
  end

  defp collect_artifacts(dir) do
    artifacts_dir = Path.join(dir, "artifacts")

    for name <- artifacts_dir |> File.ls!() |> Enum.sort(),
        path = Path.join(artifacts_dir, name),
        File.regular?(path) do
      %{name: Path.basename(name), binary: File.read!(path)}
    end
  end

  defp find_python do
    case System.find_executable("python") || System.find_executable("python3") do
      nil -> {:error, "no python interpreter found on PATH"}
      path -> {:ok, path}
    end
  end

  defp enabled? do
    Application.get_env(:flux, __MODULE__, [])[:enabled] == true
  end
end
