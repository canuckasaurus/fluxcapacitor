defmodule Flux.Engine.SchemaCheck do
  @moduledoc """
  Just-enough JSON-schema validation for structured LLM output: `type`,
  `required`, `properties`, `items`, and `enum`. Returns human-readable
  error strings meant to be quoted back to the model on retry.
  """

  @doc "`:ok` or `{:error, [\"path: problem\", ...]}`."
  def validate(value, schema) when is_map(schema) do
    case check(value, schema, "output") do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(_value, _schema), do: :ok

  defp check(value, schema, path) do
    type_errors = check_type(value, schema["type"], path)

    if type_errors == [] do
      check_enum(value, schema["enum"], path) ++
        check_object(value, schema, path) ++
        check_items(value, schema, path)
    else
      type_errors
    end
  end

  defp check_type(_value, nil, _path), do: []

  defp check_type(value, type, path) do
    if of_type?(value, type) do
      []
    else
      ["#{path}: expected #{inspect(type)}, got #{type_name(value)}"]
    end
  end

  defp of_type?(value, types) when is_list(types), do: Enum.any?(types, &of_type?(value, &1))
  defp of_type?(value, "object"), do: is_map(value)
  defp of_type?(value, "array"), do: is_list(value)
  defp of_type?(value, "string"), do: is_binary(value)
  defp of_type?(value, "number"), do: is_number(value)
  defp of_type?(value, "integer"), do: is_integer(value)
  defp of_type?(value, "boolean"), do: is_boolean(value)
  defp of_type?(value, "null"), do: is_nil(value)
  defp of_type?(_value, _unknown), do: true

  defp type_name(value) when is_map(value), do: "object"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_number(value), do: "number"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(nil), do: "null"
  defp type_name(_value), do: "unknown"

  defp check_enum(_value, nil, _path), do: []

  defp check_enum(value, allowed, path) when is_list(allowed) do
    if value in allowed do
      []
    else
      ["#{path}: must be one of #{inspect(allowed)}"]
    end
  end

  defp check_object(value, %{"type" => "object"} = schema, path) when is_map(value) do
    required =
      for name <- List.wrap(schema["required"]), not Map.has_key?(value, name) do
        "#{path}.#{name}: required property missing"
      end

    nested =
      for {name, property} <- schema["properties"] || %{},
          Map.has_key?(value, name),
          error <- check(value[name], property, "#{path}.#{name}") do
        error
      end

    required ++ nested
  end

  defp check_object(_value, _schema, _path), do: []

  defp check_items(value, %{"type" => "array", "items" => items}, path)
       when is_list(value) and is_map(items) do
    for {element, index} <- Enum.with_index(value),
        error <- check(element, items, "#{path}[#{index}]") do
      error
    end
  end

  defp check_items(_value, _schema, _path), do: []
end
