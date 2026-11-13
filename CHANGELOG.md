# Changelog

## 0.2.0

- Each test file now records the modules it executed, and its fingerprint includes a digest of their compiled `.beam` files. A change to a macro, a case template or a value inlined at compile time selects only the test files that executed a module compiled with it.
- The digest is `Tia.Beam.digest/1`, not `:beam_lib.md5/1`: a macro that walks a map (HEEx slots, `@derive Jason.Encoder`, a Commanded router) emits its code in an order that changes between two compilations of the same sources, which left test files stale after any recompilation. The digest hashes the expanded code of the `debug_info` chunk with positions dropped and with function clauses, map keys and list literals sorted, and falls back to the md5 for a module without Elixir debug information. It does not see a compile-time change that only reorders those.
- Files that define macros no longer belong to the globals, so changing one no longer reruns the whole suite.
- Breaking: the `:macro_globs` and `:macro_markers` options are removed; setting them raises. Remove them from the `:tia` key of `mix.exs`.
- New `:ebin` option: the directory of the compiled `.beam` files, by default `Mix.Project.compile_path/0`.
- `mix tia` compiles the project before computing the selection, in every mode, including `--check` and `--dry-run`.
- The map format is now version 4, with a `modules` list per test file. A map of an older version is recorded again in full on the next `mix tia`.
- Breaking: `Tia.Map.put/4` is now `put/5` and takes the executed module names; `Tia.Recorder.executed_sources/2` is replaced by `executed_modules/1` and `sources/2`.
- New `--partitions N` option and `:partitions` config: recording splits the test files across `N` `mix tia` processes that run in parallel, each with `MIX_TEST_PARTITION` set from `1` to `N`, and merges their results into the map. `ExUnit.after_suite` callbacks run once per partition. The default of `1` records in the calling process, as before. The partitions do not compile the project again or wait for the lock of the build directory, and their lines are printed without ANSI escapes.
- Fix: `mix tia --all --only GLOB` emptied the map before recording the matching test files. It now replaces only their entries, unless the globals changed.
- Recording prints one line per test file (`tia: [12/749] test/foo_test.exs`) and the failures in full, instead of the whole ExUnit output for each file. The formatters configured in `test_helper.exs` are replaced by `Tia.Formatter` while recording.
- New `:ignore_modules` option: modules, or prefixes of module names, that never enter the map, for the code that background processes run.
- `--partitions` now feeds the processes from one queue instead of splitting the test files in fixed groups: a process asks for the next test file when it finishes the one it has, so a slow file no longer leaves the other partitions waiting at the end. The progress lines count over the whole run, as in `[2] tia: [12/749] test/foo_test.exs`. A process that dies loses the test file it was recording and the ones it recorded since it last saved (every 50 files); the others go on with the rest of the queue.
- Each entry of the map records `ms`, the time its recording took, and the queue hands out the slowest test files first; test files with no duration go before them. `ms` is not part of the fingerprint and the map stays at version 4: an entry without `ms` is read as before. `Tia.Map.put/6` takes the duration and `Tia.Map.durations/1` reads them.
- New local hash cache, `.tia/cache.bin` (`Tia.Cache`, `:cache` option, `false` to turn it off): the hash of a source or of a module is reused while the modification time and the size of its file are the same. Add `/.tia/cache.bin` to `.gitignore`.
- The digest of a module no longer depends on the path of the checkout: `Tia.Beam.digest/2` takes the root of the project and swaps it for a placeholder in the strings and charlists of the expanded code, which is where `__ENV__.file` ends up. Modules that embed their path get a new digest, so their test files are recorded once more.
- The digest of a module leaves out the definitions of `__mix_recompile__?/0` and `__phoenix_recompile__?/0`, the hooks that tell Mix (and the `:phoenix` compiler of Phoenix up to 1.6) when to recompile a module. `embed_templates` of `Phoenix.Template` puts there the md5 of the absolute paths of the templates, which the swap of the root cannot reach, so the same commit gave another digest in another directory for every module with embedded templates. Modules that define one of these functions get a new digest, so their test files are recorded once more.
- `partitions: :auto` and `--partitions auto` use half of `System.schedulers_online/0`, at least one. The default is still `1`.

## 0.1.1

- Only `config/config.exs`, `config/test.exs` and `config/runtime.exs` are global by default; changes to other env configs no longer rerun the whole suite. Maps recorded before move their globals once.
- Recording runs `ExUnit.after_suite` callbacks once, at the end, instead of after every test file.
- `--check` diffs against the merge base with `:base`, and falls back to the whole suite with a clear reason when the ref cannot be resolved.

## 0.1.0

First release, extracted from an internal tool.

- `mix tia` records which source files each test file executes.
- `mix tia --check` runs only the test files a diff can affect.
- Recording uses the JIT's native function counters instead of `:cover`.
- `@external_resource` files are recorded as sources.
- Configuration through the `:tia` project key.
