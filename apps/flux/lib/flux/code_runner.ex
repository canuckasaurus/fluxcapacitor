defmodule Flux.CodeRunner do
  @moduledoc """
  Executes workflow code blocks. Spec:
  `%{language, code, dependencies, inputs, timeout_ms}` →
  `{:ok, %{result: map, stdout: binary}}` or `{:error, message}`.

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

  @callback run(spec()) :: {:ok, %{result: map(), stdout: String.t()}} | {:error, String.t()}

  def run(spec), do: impl().run(spec)

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
        {:ok, %{result: result, stdout: body["stdout"] || ""}}

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

        task =
          Task.async(fn ->
            System.cmd(python, ["wrapper.py"], cd: dir, stderr_to_stdout: true)
          end)

        case Task.yield(task, spec.timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            result = dir |> Path.join("__result__.json") |> File.read!() |> Jason.decode!()
            {:ok, %{result: result, stdout: output}}

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
