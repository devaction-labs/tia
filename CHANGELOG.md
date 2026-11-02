# Changelog

## 0.1.0

First release, extracted from an internal tool.

- `mix tia` records which source files each test file executes.
- `mix tia --check` runs only the test files a diff can affect.
- Recording uses the JIT's native function counters instead of `:cover`.
- `@external_resource` files are recorded as sources.
- Configuration through the `:tia` project key.
