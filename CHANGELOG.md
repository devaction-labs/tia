# Changelog

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
