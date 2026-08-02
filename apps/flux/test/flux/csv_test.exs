defmodule Flux.CSVTest do
  use ExUnit.Case, async: true

  alias Flux.CSV

  test "parses quoted fields, embedded commas, quotes, and newlines" do
    csv = "name,notes\r\nAda,\"loves, math\"\r\nGrace,\"said \"\"hi\"\"\nand left\"\r\n"

    assert CSV.parse(csv) == [
             ["name", "notes"],
             ["Ada", "loves, math"],
             ["Grace", "said \"hi\"\nand left"]
           ]
  end

  test "parse_with_header zips rows into maps and drops blank lines" do
    csv = "query,tone\nhello,friendly\n\ngoodbye,curt\n"

    assert {:ok, rows} = CSV.parse_with_header(csv)

    assert rows == [
             %{"query" => "hello", "tone" => "friendly"},
             %{"query" => "goodbye", "tone" => "curt"}
           ]
  end

  test "parse_with_header pads short rows and rejects blank headers" do
    assert {:ok, [%{"a" => "1", "b" => ""}]} = CSV.parse_with_header("a,b\n1\n")
    assert {:error, :invalid_header} = CSV.parse_with_header("a,,c\n1,2,3\n")
    assert {:error, :empty} = CSV.parse_with_header("")
  end

  test "encode round-trips through parse" do
    rows = [["h1", "h2"], ["plain", "with, comma"], ["with \"quote\"", "multi\nline"]]
    assert rows |> CSV.encode() |> CSV.parse() == rows
  end
end
