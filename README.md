# Tia

Test impact analysis for ExUnit: run only the test files a change can affect.

Tia records which modules and source files each test file executes. On the
next run it compares content hashes of the sources and the digests of the
compiled modules against the disk, and picks the test files whose recorded
sources or modules changed. The map validates itself, so it needs no help from
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
$ mix tia                   # record the stale test files, update the map
$ mix tia --all             # record every test file
$ mix tia --partitions 4    # record in 4 operating system processes
$ mix tia --partitions auto # one process for every two cores
$ mix tia --check           # CI: run the affected test files, change nothing
$ mix tia --dry-run         # only print the selection
```

Recording runs each test file on its own, one at a time. A file whose tests
fail is not recorded, stays stale, and makes the task exit with an error.

While it records, `mix tia` prints one line per test file and the failures in
full:

```console
tia: [12/749] test/my_app/accounts_test.exs
```

The formatters you configure in `test_helper.exs` are replaced by
`Tia.Formatter` for the recording; `mix tia --check` runs `mix test` and keeps
them.

`--all` records every test file again. With `--only GLOB` it replaces only the
entries of the matching test files and keeps the rest of the map, unless a
global file changed, which empties the map first.

On a large suite, `--partitions N` (or the `:partitions` option) records with
`N` `mix tia` processes that run in parallel and take the test files from one
queue. Each one still runs its files one at a time, and the results are merged
into the map at the end. Their output is prefixed with `[1] ` to `[N] `. See
[Partitions](#partitions) before you use it with a database.

`--check` runs the stale test files plus those whose recorded sources appear in
`git diff --name-only BASE`. It runs the whole suite when the map is missing or
when a global file changed.

Every mode compiles the project first: the selection reads the compiled
`.beam` files.

## What to commit

Commit the map, `.tia/map.json`, so that CI and your colleagues start from it.
Keep the local hash cache out of version control:

```gitignore
# .gitignore
/.tia/cache.bin
/.tia/partitions/
```

`.tia/partitions/` only exists while `--partitions` runs. The cache is
described in [The hash cache](#the-hash-cache).

Each line of the map holds one test file: its fingerprint, the modules and
sources it executed, and `ms`, the time its recording took. `ms` is not part
of the fingerprint. It changes every time the test file is recorded again,
and only then.

## What forces the whole suite

A per-test map cannot see everything, so these files share one fingerprint and
any change to them selects every test file:

- `mix.exs`, `mix.lock`, `.tool-versions`, `test/test_helper.exs`
- `config/config.exs`, `config/test.exs`, `config/runtime.exs` and
  `priv/*/migrations/*.exs`

Files that define macros are not on this list. A change to a macro, to a case
template (`use MyApp.DataCase`) or to a module like `MyAppWeb` selects only the
test files that executed a module compiled with it; see
[How recording works](#how-recording-works).

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

`:ignore_modules` keeps modules out of the map. An atom is one module, a
string is a prefix of the module name:

```elixir
tia: [ignore_modules: [MyApp.PromEx, "MyApp.Telemetry"]]
```

Use it for the code your background processes run; see
[Limitations](#limitations). A change to an ignored module selects no test
file through it.

## How recording works

Tia switches the VM to native function counters
(`:code.set_coverage_mode(:function_counters)`) and reloads your application's
modules. Nothing is recompiled, and reading or zeroing the counters of a
thousand modules takes under a millisecond, so recording costs about the same
as running the tests. `:cover` spent over a second per test file on the same
project.

A module counts as executed when any of its functions was entered. Its name,
its source and its `@external_resource` files, such as templates, go into the
map. Macros count too: a case template whose `__using__/1` expands while the
test file is compiled is executed by that test file.

The fingerprint of a test file covers the content of those files and a digest
of the compiled `.beam` file of each of those modules (`Tia.Beam.digest/1`).
So when you change a macro, or a function whose result another module embeds
at compile time (`@limit B.limit()`), Mix recompiles the dependent modules and
only the test files that executed one of them, with different code, become
stale. A recorded module whose `.beam` file is gone also makes its test files
stale.

The digest is not the checksum of the file. Two compilations of the same
sources do not always give the same `.beam`: a macro that builds code by
walking a map (the slots of a HEEx component, `@derive Jason.Encoder`, a
Commanded router) emits it in an order that changes from one compilation to
the next. Tia hashes the expanded code in the `debug_info` chunk instead, with
line numbers dropped and with the function clauses, map keys and list literals
sorted. In a Phoenix application with 1112 modules, 69 had a `.beam` checksum
that changed across four `mix compile --force` runs of the same sources, and
none had a digest that changed; the digest of the 80 modules that expand
`use MyAppWeb, :live_view` changed when that macro got a new function, and no
digest changed when it got a new comment. That is what was verified: one
project, one machine, one checkout. The rules are a heuristic, so another
macro library can still give two digests for the same sources, which only
selects more tests. Another Elixir or OTP version can expand the same source
differently, so a map recorded with other versions may start with stale test
files. A module without Elixir debug information falls back to
`:beam_lib.md5/1`.

The digest does not depend on where the checkout is. Code that embeds
`__ENV__.file`, as the Phoenix macros do, carries the absolute path of the
project in its literals; Tia swaps the root of the project for a placeholder
in every string and charlist before it hashes, so a map recorded in
`/home/you/my_app` is still current in `/builds/my_app` on CI. A hash of a
path is out of reach of that swap, so the definitions of `__mix_recompile__?/0`
and `__phoenix_recompile__?/0` are ignored: they only tell Mix when to
recompile a module, and `embed_templates` of Phoenix puts there the md5 of the
absolute paths of the templates. This is covered by tests that compile one
module in two directories; it has not been verified between two real machines
yet.

The digest is read from the file on disk (the `:ebin` option, by default
`Mix.Project.compile_path/0`), never from the loaded module, because the
function counters change the loaded code.

The counters are global to the VM, which is why one VM records one test file
at a time and why `--partitions` uses separate operating system processes
instead of concurrency inside one.

## The hash cache

Every run hashes all the test files, all the recorded sources and all the
recorded modules to find what is stale. `mix tia` keeps those hashes in
`.tia/cache.bin`, each under the absolute path of its file together with the
modification time and the size the file had, and reuses a hash while both are
the same. On a synthetic project with 749 test files and 1112 modules, on 16
cores, finding the stale test files took 541 ms without the cache and 74 ms
with it; compiling and starting Mix are not in those numbers and take the
same time either way.

The cache belongs to one checkout and is safe to delete. A cache that is
damaged or comes from another version of Tia is ignored. Two things to know:

- A file modified less than two seconds ago is hashed and not cached, because
  the modification time has a resolution of one second. Right after a
  compilation the modules are hashed once more.
- A tool that changes a file and keeps both its size and its modification
  time (`cp -p`, `touch -r`, some archive extractors) leaves the old hash in
  place. Delete the cache, or turn it off, if you use one:

```elixir
tia: [cache: false]
```

`:cache` also takes another path, relative to the project root or absolute.

## Partitions

`--partitions N` starts `N` processes and one queue. A process asks for the
next test file when it finishes the one it has, so a slow file holds back only
the process that runs it. The queue starts with the test files the map has no
duration for, followed by the others from the slowest to the fastest, so the
long ones go first and the partitions finish close to each other. The
progress counts over the whole run:

```console
[2] tia: [12/749] test/my_app/accounts_test.exs
```

If a process dies, the test file it was recording and the ones it recorded
since it last saved its results (it saves every 50 files) count as failed and
stay stale. The other processes go on with the rest of the queue.

`--partitions auto`, or `partitions: :auto`, uses half of
`System.schedulers_online/0`, at least one. The default stays `1`: more
partitions need the database setup below.

Each process of `--partitions N` gets `MIX_TEST_PARTITION` set to its number,
from `1` to `N`, the convention of `mix test --partitions`. If your tests use
a database, give each partition its own, or they will step on each other:

```elixir
# config/test.exs
config :my_app, MyApp.Repo,
  database: "my_app_test#{System.get_env("MIX_TEST_PARTITION")}"
```

Each partition starts your application, so each one opens the whole pool of
the Repo: `N` partitions hold `N × pool_size` connections, which can pass the
`max_connections` of the database. With `auto` on a machine with 16 cores that
is 8 partitions: a pool of 32 connections each would ask for 256, and
PostgreSQL allows 100 by default. Recording runs one test at a time
(`max_cases: 1`), so a partition needs few connections:

```elixir
# config/test.exs
config :my_app, MyApp.Repo,
  pool_size: if(System.get_env("MIX_TEST_PARTITION"), do: 5, else: System.schedulers_online() * 2)
```

The project is compiled once, before the partitions start; they only load it.
Every partition loads `test_helper.exs`, so anything it sets up, such as the
Ecto sandbox or migrations, runs once per partition, and `ExUnit.after_suite`
callbacks run once per partition with the totals of that partition. With one
partition, or a single test file to record, everything runs in the calling
process and `MIX_TEST_PARTITION` is not set.

## Limitations

Selection is a speedup, not a proof. Keep a full run on your main branch.

- **Compile-time dependencies Mix does not track.** A value inlined from
  another module (`@limit B.limit()`, a `%B{}` default, a macro expansion) is
  covered, because Mix recompiles the dependent module and its `.beam` changes.
  Anything a module reads at compile time without telling Mix (a file with no
  `@external_resource`, an environment variable) is not.
- **Data dependencies.** Files read at runtime are invisible unless a module
  declares them with `@external_resource`.
- **Excluded tests.** Tests skipped by tags during recording contribute nothing
  to the map.
- **Compile-time changes that only reorder.** The digest of a module ignores
  the order of its function clauses, of the keys of a map, of the elements of
  a list literal and of the words of the strings in one. A macro or an inlined
  value that changes only such an order, as in `@steps B.steps()` going from
  `[:a, :b]` to `[:b, :a]`, does not make the dependent modules stale. A change
  to the module's own file always does.
- **Background processes.** Anything running while a test file runs is charged
  to it: the modules of a telemetry poller, of PromEx or of a timer show up in
  the entries of whichever test files were running when they fired. That can
  only select more tests, never fewer, but it makes those test files stale
  when such a module changes. List them in `:ignore_modules` to keep them out.

Hub modules also limit the gain: a file that most tests execute selects most of
the suite when it changes.

## Credits

Tia is inspired by the `--tia` option of [Pest](https://pestphp.com) 5, created
by [Nuno Maduro](https://github.com/nunomaduro). Tia is an independent project
for ExUnit, with no affiliation to Pest.
