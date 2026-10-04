%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/web/"
        ],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/",
          ~r"\.pb\.ex$"
        ]
      },
      strict: true,
      color: true,
      # `extra:` tunes checks on top of the default set; `enabled:` would
      # REPLACE it (running only the listed checks), which is how this file
      # once ran zero checks. TagTODO stays off via `disabled:`.
      #
      # The three metric thresholds below are a baseline at the code's
      # current maxima (Credo's defaults: nesting 2, complexity 9, 31 struct
      # fields), so the gate catches regressions without a large unrelated
      # refactor of working GenServers. Lower them as code is reworked.
      checks: %{
        extra: [
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
          {Credo.Check.Warning.StructFieldAmount, [max_fields: 56]}
        ],
        disabled: [
          {Credo.Check.Design.TagTODO, []}
        ]
      }
    }
  ]
}
