defmodule Flux.Engine.SchemaCheckTest do
  use ExUnit.Case, async: true

  alias Flux.Engine.SchemaCheck

  @schema %{
    "type" => "object",
    "required" => ["name", "tags"],
    "properties" => %{
      "name" => %{"type" => "string"},
      "age" => %{"type" => "integer"},
      "mood" => %{"type" => "string", "enum" => ["happy", "sad"]},
      "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
      "address" => %{
        "type" => "object",
        "required" => ["city"],
        "properties" => %{"city" => %{"type" => "string"}}
      }
    }
  }

  test "a conforming value passes" do
    value = %{
      "name" => "Doc",
      "age" => 65,
      "mood" => "happy",
      "tags" => ["scientist"],
      "address" => %{"city" => "Hill Valley"}
    }

    assert :ok = SchemaCheck.validate(value, @schema)
  end

  test "missing requireds, bad types, bad enums, and bad items all report with paths" do
    value = %{
      "age" => "old",
      "mood" => "angry",
      "tags" => ["ok", 42],
      "address" => %{}
    }

    assert {:error, errors} = SchemaCheck.validate(value, @schema)
    joined = Enum.join(errors, "\n")

    assert joined =~ "output.name: required property missing"
    assert joined =~ "output.age: expected \"integer\", got string"
    assert joined =~ "output.mood: must be one of"
    assert joined =~ "output.tags[1]: expected \"string\", got integer"
    assert joined =~ "output.address.city: required property missing"
  end

  test "a non-object root is a type error, not a crash" do
    assert {:error, ["output: expected \"object\"" <> _rest]} =
             SchemaCheck.validate("just text", @schema)
  end

  test "union types accept any member" do
    schema = %{"type" => ["string", "null"]}
    assert :ok = SchemaCheck.validate("hello", schema)
    assert :ok = SchemaCheck.validate(nil, schema)
    assert {:error, _errors} = SchemaCheck.validate(5, schema)
  end
end
