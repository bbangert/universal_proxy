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
      checks: %{
        enabled: [
          {Credo.Check.Design.TagTODO, false}
        ]
      }
    }
  ]
}
