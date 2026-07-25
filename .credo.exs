%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["apps/*/lib/", "apps/*/test/", "packages/*/lib/", "config/"],
        excluded: ["apps/*/deps/", "_build/"]
      },
      strict: true,
      checks: %{
        extra: [
          # Repo.transact(fn -> with ... do ... end end) is our standard
          # multi-step write pattern; it nests three deep by construction.
          {Credo.Check.Refactor.Nesting, max_nesting: 3},
          # Fully-qualified one-off module references in function bodies are
          # fine; forcing top-level aliases for them hurts readability.
          {Credo.Check.Design.AliasUsage, false}
        ]
      }
    }
  ]
}
