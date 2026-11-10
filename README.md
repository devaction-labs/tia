# Tia

Test impact analysis for ExUnit: run only the test files a change can affect.

Tia records which source files each test file executes. On the next run it
compares content hashes against the disk and picks the test files whose
recorded sources changed. The map validates itself, so it needs no help from
`git`, and it is a plain JSON file you can commit.

## Installation

```elixir
def deps do
  [{:tia, "~> 0.1", only: [:dev, :test], runtime: false}]
end

def cli do
  [preferred_envs: [tia: :test]]
end
```

Requires Elixir 1.18+ and OTP 27+ running under the JIT. There are no runtime
dependencies.

## Usage

```console
$ mix tia                # record the stale test files, update the map
$ mix tia --all          # record every test file
$ mix tia --check        # CI: run the affected test files, change nothing
$ mix tia --dry-run      # only print the selection
```

Recording runs each test file on its own, one at a time. A file whose tests
fail is not recorded, stays stale, and makes the task exit with an error.

`--check` runs the stale test files plus those whose recorded sources appear in
`git diff --name-only BASE`. It runs the whole suite when the map is missing or
when a global file changed.

## What forces the whole suite

A per-test map cannot see everything, so these files share one fingerprint and
any change to them selects every test file:

- `mix.exs`, `mix.lock`, `.tool-versions`, `test/test_helper.exs`
- `config/config.exs`, `config/test.exs`, `config/runtime.exs` and
  `priv/*/migrations/*.exs`
- any file under `lib/` or `test/support/` that defines macros

If your config imports other files (for example `import_config "test/*.exs"`),
add them to `:global_globs` or `:extra_global_files`.

## Configuration

```elixir
def project do
  [
    # ...
    tia: [
      base: "develop",
      extra_global_files: ["priv/repo/seeds.exs"]
    ]
  ]
end
```

`Tia.Config` lists every option. If `test_helper.exs` loads other files, such as
seeds, add them to `:extra_global_files`: Tia cannot see them otherwise.

## How recording works

Tia switches the VM to native function counters
(`:code.set_coverage_mode(:function_counters)`) and reloads your application's
modules. Nothing is recompiled, and reading or zeroing the counters of a
thousand modules takes under a millisecond, so recording costs about the same
as running the tests. `:cover` spent over a second per test file on the same
project.

A module counts as executed when any of its functions was entered. Its source
and its `@external_resource` files, such as templates, go into the map.

## Limitations

Selection is a speedup, not a proof. Keep a full run on your main branch.

- **Values inlined at compile time.** If module `A` embeds a value from `B`
  (`@limit B.limit()`, or a `%B{}` default) and the tests never call `B`, a
  change to `B` does not select them.
- **Data dependencies.** Files read at runtime are invisible unless a module
  declares them with `@external_resource`.
- **Excluded tests.** Tests skipped by tags during recording contribute nothing
  to the map.
- **Background processes.** Anything running while a test file runs is charged
  to it. That can only select more tests, never fewer.

Hub modules also limit the gain: a file that most tests execute selects most of
the suite when it changes.

## Credits

Tia is inspired by the `--tia` option of [Pest](https://pestphp.com) 5, created
by [Nuno Maduro](https://github.com/nunomaduro). Tia is an independent project
for ExUnit, with no affiliation to Pest.
