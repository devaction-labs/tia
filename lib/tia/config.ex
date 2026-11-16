defmodule Tia.Config do
  @moduledoc """
  Where the map lives and which files count as global.

  Set under the `:tia` key of `project/0` in `mix.exs`. Every key is optional.

    * `:map` - path of the map file, default `".tia/map.json"`
    * `:base` - git ref `mix tia --check` diffs against, default `"main"`
    * `:global_files` - files whose change reruns everything
    * `:extra_global_files` - more such files, added to `:global_files`
    * `:global_globs` - globs whose change reruns everything
    * `:ebin` - directory of the project's compiled `.beam` files, relative to
      `:root` or absolute. `mix tia` defaults it to `Mix.Project.compile_path/0`;
      without it every recorded module counts as missing
    * `:test_globs` - globs of the test files
    * `:ignore_modules` - modules that never enter the map, default `[]`. An
      atom is one module; a string is a prefix of the module name, so
      `"MyApp.Telemetry"` covers `MyApp.Telemetry` and
      `MyApp.Telemetry.Poller`. Meant for code that background processes run
      while any test file runs. A change to an ignored module selects no test
      file through it
    * `:partitions` - how many operating system processes `mix tia` records
      with, default `1`. Each one is a separate VM that gets
      `MIX_TEST_PARTITION` set to its number, starting at `1`, and runs the
      `ExUnit.after_suite` callbacks once for its own share of the test files.
      `:auto` means half of `System.schedulers_online/0`, at least `1`. Every
      partition starts the application, so with a database each one opens
      its own connection pool. `mix tia --partitions N` overrides it
    * `:cache` - path of the local hash cache, relative to `:root` or
      absolute, default `".tia/cache.bin"`, or `false` to do without it. See
      `Tia.Cache`. `mix tia` opens it; the functions of `Tia.Map` only use a
      cache that `Tia.Cache.attach/1` opened. The durations of the recordings
      are kept in the same directory, in `durations.bin`, and not at all
      when this is `false`; see `Tia.Durations`
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
    ebin: nil,
    test_globs: ["test/**/*_test.exs"],
    ignore_modules: [],
    partitions: 1,
    cache: ".tia/cache.bin"
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
          ebin: Path.t() | nil,
          test_globs: [String.t()],
          ignore_modules: [module() | String.t()],
          partitions: pos_integer() | :auto,
          cache: Path.t() | false | Tia.Cache.t() | nil
        }

  @doc "Builds a config from the given options; an unknown key raises."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, Keyword.merge(@defaults, opts))
end
