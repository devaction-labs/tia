defmodule Tia.Config do
  @moduledoc """
  Where the map lives and which files count as global.

  Set under the `:tia` key of `project/0` in `mix.exs`. Every key is optional.

    * `:map` - path of the map file, default `".tia/map.json"`
    * `:base` - git ref `mix tia --check` diffs against, default `"main"`
    * `:global_files` - files whose change reruns everything
    * `:extra_global_files` - more such files, added to `:global_files`
    * `:global_globs` - globs whose change reruns everything
    * `:macro_globs` - globs scanned for files that define macros
    * `:macro_markers` - substrings that mark a file as defining macros
    * `:test_globs` - globs of the test files
    * `:root` - project root, default `"."`

  List keys replace their default.
  """

  @defaults [
    root: ".",
    map: ".tia/map.json",
    base: "main",
    global_files: ["mix.exs", "mix.lock", ".tool-versions", "test/test_helper.exs"],
    extra_global_files: [],
    global_globs: [
      "config/config.exs",
      "config/test.exs",
      "config/runtime.exs",
      "priv/*/migrations/*.exs"
    ],
    macro_globs: ["lib/**/*.ex", "test/support/**/*.ex"],
    macro_markers: ["defmacro", "using do", "using("],
    test_globs: ["test/**/*_test.exs"]
  ]

  @enforce_keys Keyword.keys(@defaults)
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          root: Path.t(),
          map: Path.t(),
          base: String.t(),
          global_files: [Path.t()],
          extra_global_files: [Path.t()],
          global_globs: [String.t()],
          macro_globs: [String.t()],
          macro_markers: [String.t()],
          test_globs: [String.t()]
        }

  @doc "Builds a config from the given options; an unknown key raises."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, Keyword.merge(@defaults, opts))
end
