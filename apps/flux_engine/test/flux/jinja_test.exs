defmodule Flux.Engine.JinjaTest do
  use ExUnit.Case, async: true

  alias Flux.Engine.Jinja

  defp render!(template, context) do
    {:ok, output} = Jinja.render(template, context)
    output
  end

  test "variables, dotted paths, and undefineds" do
    context = %{"start" => %{"query" => "hello", "user" => %{"name" => "Marty"}}}

    assert render!("Hi {{ start.user.name }}: {{ start.query }}", context) == "Hi Marty: hello"
    assert render!("missing: [{{ nope.nothing }}]", context) == "missing: []"
    assert render!("literal {{ 'quoted' }} and {{ 42 }}", %{}) == "literal quoted and 42"
  end

  test "filters chain and take arguments" do
    context = %{
      "name" => "  emmett brown  ",
      "tags" => ["flux", "time", "88mph"],
      "long" => String.duplicate("x", 30)
    }

    assert render!("{{ name | trim | upper }}", context) == "EMMETT BROWN"
    assert render!("{{ name | trim | capitalize }}", context) == "Emmett brown"
    assert render!("{{ tags | join(\", \") }}", context) == "flux, time, 88mph"
    assert render!("{{ tags | length }}", context) == "3"
    assert render!("{{ tags | first }}/{{ tags | last }}", context) == "flux/88mph"
    assert render!("{{ missing | default(\"n/a\") }}", context) == "n/a"
    assert render!("{{ long | truncate(5) }}", context) == "xxxxx…"
    assert render!("{{ name | trim | replace(\" \", \"_\") }}", context) == "emmett_brown"
    assert render!("{{ tags | json }}", context) == ~s(["flux","time","88mph"])
  end

  test "if / elif / else with comparisons and logic" do
    template = """
    {% if score >= 90 %}A{% elif score >= 50 %}B{% else %}F{% endif %}\
    """

    assert render!(template, %{"score" => 95}) == "A"
    assert render!(template, %{"score" => 60}) == "B"
    assert render!(template, %{"score" => 10}) == "F"

    assert render!("{% if name == 'Doc' and ready %}go{% endif %}", %{
             "name" => "Doc",
             "ready" => true
           }) == "go"

    assert render!("{% if broken or ready %}go{% endif %}", %{"ready" => true}) == "go"
    assert render!("{% if not missing %}empty{% endif %}", %{}) == "empty"
    # Numbers compare loosely with their string forms.
    assert render!("{% if count == 3 %}three{% endif %}", %{"count" => "3"}) == "three"
  end

  test "for loops with loop metadata, nesting, and JSON strings" do
    template = """
    {% for item in items %}{{ loop.index }}:{{ item.name }}{% if not loop.last %}, {% endif %}{% endfor %}\
    """

    context = %{"items" => [%{"name" => "a"}, %{"name" => "b"}, %{"name" => "c"}]}
    assert render!(template, context) == "1:a, 2:b, 3:c"

    # A JSON-encoded list (how lists ride through pools) iterates too.
    assert render!("{% for n in nums %}{{ n }}.{% endfor %}", %{"nums" => "[1,2,3]"}) == "1.2.3."

    nested = "{% for row in grid %}{% for cell in row %}{{ cell }}{% endfor %};{% endfor %}"
    assert render!(nested, %{"grid" => [[1, 2], [3, 4]]}) == "12;34;"
  end

  test "comments strip and malformed templates error" do
    assert render!("a{# not shown #}b", %{}) == "ab"

    assert {:error, message} = Jinja.render("{% if x %}unclosed", %{})
    assert message =~ "endif"

    assert {:error, message} = Jinja.render("{% frob %}", %{})
    assert message =~ "unknown tag"

    assert {:error, message} = Jinja.render("stray {% endfor %}", %{})
    assert message =~ "endfor"
  end
end
