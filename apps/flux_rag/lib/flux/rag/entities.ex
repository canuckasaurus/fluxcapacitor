defmodule Flux.RAG.Entities do
  @moduledoc """
  Deterministic entity extraction — the GraphRAG groundwork. Capitalized
  runs and acronyms in segment text become `rag_entities` rows linked to
  their segments (`rag_entity_mentions`), forming a bipartite
  entity–segment graph: co-occurrence falls out of shared segments, and
  the same tables feed an ArangoDB graph traversal later without schema
  changes. No model calls, so extraction is free and CI-hermetic; an
  LLM-based extractor can replace `extract/1` behind the same shape.
  """

  @max_entities_per_text 50

  # Common sentence-leading words that capitalize without naming anything.
  @stopwords MapSet.new(~w(the a an this that these those it its his her their our your my
                i we you they he she who what when where why how which is are was were be
                been am and or but if then else for nor not no yes on in at by to from of
                with as so do does did done can could will would should may might must))

  @doc """
  Normalized entity names found in the text: multiword capitalized runs
  ("Acme Corp"), acronyms (NASA), and capitalized words that aren't
  common sentence-starters. Lowercased, deduplicated, capped.
  """
  def extract(text) when is_binary(text) do
    ~r/\b[A-Z][A-Za-z0-9&\-]*(?:[ \t][A-Z][A-Za-z0-9&\-]*)*\b/
    |> Regex.scan(text)
    |> Enum.map(fn [match | _groups] -> trim_leading_stopwords(match) end)
    |> Enum.filter(&candidate?/1)
    |> Enum.map(&normalize/1)
    |> Enum.uniq()
    |> Enum.take(@max_entities_per_text)
  end

  def extract(_text), do: []

  @doc "The stored form of an entity name (for lookups)."
  def normalize(name) do
    name |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # "The Flux Capacitor" → "Flux Capacitor": sentence-initial furniture
  # capitalizes and joins the run, but it is not part of the name.
  defp trim_leading_stopwords(match) do
    match
    |> String.split(~r/[ \t]/)
    |> Enum.drop_while(&MapSet.member?(@stopwords, String.downcase(&1)))
    |> Enum.join(" ")
  end

  defp candidate?(""), do: false

  defp candidate?(match) do
    cond do
      # Multiword runs ("Flux Capacitor") are the strongest signal.
      match =~ ~r/[ \t]/ -> true
      # Acronyms: 2–8 uppercase letters.
      match =~ ~r/^[A-Z]{2,8}$/ -> true
      # Single capitalized words count unless they're sentence furniture.
      true -> String.length(match) >= 3 and not MapSet.member?(@stopwords, String.downcase(match))
    end
  end
end
