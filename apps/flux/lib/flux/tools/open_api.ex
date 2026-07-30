defmodule Flux.Tools.OpenAPI do
  @moduledoc """
  Parses an OpenAPI 3.x (or Swagger 2) document — JSON or YAML — into the
  flat operation list a toolset stores: one entry per path+method with its
  callable parameters (path/query/header plus first-level JSON body
  properties).

  Deliberately tolerant: unknown keywords are ignored, `$ref`s resolve one
  document-local level, and operations missing an `operationId` get one
  derived from the method and path.
  """

  @methods ~w(get post put patch delete)
  @ref_depth 5

  @doc """
  Returns `{:ok, %{title, description, base_url, operations}}` or
  `{:error, message}`. Operations are JSONB-safe maps with string keys.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    with {:ok, doc} <- decode(text),
         :ok <- validate(doc) do
      operations =
        for {path, item} <- Map.get(doc, "paths", %{}),
            is_map(item),
            {method, op} <- item,
            method in @methods,
            is_map(op) do
          operation(doc, path, method, item, op)
        end

      {:ok,
       %{
         title: get_in(doc, ["info", "title"]) || "Imported API",
         description: get_in(doc, ["info", "description"]),
         base_url: base_url(doc),
         operations: Enum.sort_by(operations, & &1["operation_id"])
       }}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, doc} when is_map(doc) ->
        {:ok, doc}

      _not_json ->
        case YamlElixir.read_from_string(text) do
          {:ok, doc} when is_map(doc) -> {:ok, doc}
          _not_yaml -> {:error, "The spec is neither valid JSON nor valid YAML."}
        end
    end
  end

  defp validate(doc) do
    cond do
      not (Map.has_key?(doc, "openapi") or Map.has_key?(doc, "swagger")) ->
        {:error, "Missing the openapi/swagger version field."}

      not is_map(doc["paths"]) or doc["paths"] == %{} ->
        {:error, "The spec declares no paths."}

      true ->
        :ok
    end
  end

  defp base_url(%{"servers" => [%{"url" => url} | _rest]}), do: url

  defp base_url(%{"swagger" => _v2} = doc) do
    case doc["host"] do
      host when is_binary(host) and host != "" ->
        scheme = List.first(doc["schemes"] || []) || "https"
        scheme <> "://" <> host <> (doc["basePath"] || "")

      _absent ->
        ""
    end
  end

  defp base_url(_doc), do: ""

  defp operation(doc, path, method, item, op) do
    params =
      ((item["parameters"] || []) ++ (op["parameters"] || []))
      |> Enum.map(&resolve_ref(doc, &1, @ref_depth))
      |> Enum.filter(&(is_map(&1) and &1["in"] in ~w(path query header)))
      |> Enum.map(fn param ->
        %{
          "name" => param["name"],
          "in" => param["in"],
          "required" => param["required"] == true or param["in"] == "path",
          "type" => param_type(doc, param),
          "description" => param["description"]
        }
      end)

    %{
      "operation_id" => op["operationId"] || fallback_id(method, path),
      "method" => method,
      "path" => path,
      "summary" => op["summary"] || op["description"] || "",
      "params" => params ++ body_params(doc, op)
    }
  end

  defp fallback_id(method, path) do
    slug =
      path
      |> String.replace(~r/[{}]/, "")
      |> String.replace(~r/[^\w]+/, "_")
      |> String.trim("_")

    "#{method}_#{slug}"
  end

  defp param_type(doc, param) do
    schema = resolve_ref(doc, param["schema"] || %{}, @ref_depth)
    schema["type"] || param["type"] || "string"
  end

  # First-level properties of a JSON request body become "in": "body" params.
  defp body_params(doc, op) do
    schema =
      get_in(op, ["requestBody", "content", "application/json", "schema"]) ||
        find_v2_body_schema(op)

    case resolve_ref(doc, schema, @ref_depth) do
      %{"properties" => properties} = resolved when is_map(properties) ->
        required = List.wrap(resolved["required"])

        Enum.map(properties, fn {name, prop} ->
          prop = resolve_ref(doc, prop, @ref_depth)

          %{
            "name" => name,
            "in" => "body",
            "required" => name in required,
            "type" => prop["type"] || "string",
            "description" => prop["description"]
          }
        end)

      _no_object_body ->
        []
    end
  end

  defp find_v2_body_schema(op) do
    Enum.find_value(op["parameters"] || [], fn
      %{"in" => "body", "schema" => schema} -> schema
      _other -> nil
    end)
  end

  defp resolve_ref(_doc, value, 0), do: value

  defp resolve_ref(doc, %{"$ref" => "#/" <> pointer}, depth) do
    resolved = get_in(doc, String.split(pointer, "/"))
    if is_map(resolved), do: resolve_ref(doc, resolved, depth - 1), else: %{}
  end

  defp resolve_ref(_doc, value, _depth), do: value
end
