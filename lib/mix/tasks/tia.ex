defmodule Mix.Tasks.Tia do
  @shortdoc "Runs the test files a change can affect and keeps the TIA map current"
  @moduledoc """
  Test impact analysis driven by a recorded map (`.tia/map.json` by default).

      mix tia                    # record the stale test files, update the map
      mix tia --all              # record every test file
      mix tia --partitions 4     # record in 4 operating system processes
      mix tia --partitions auto  # one process for every two cores
      mix tia --check            # CI: run the affected test files, change nothing
      mix tia --dry-run          # only print the selection

  The task must run in the test environment. As it comes from a dependency,
  Mix cannot know that by itself, so declare it in `mix.exs`:

      def cli, do: [preferred_envs: [tia: :test]]

  Recording runs each test file on its own and stores the files it executed. A
  file whose tests fail is not recorded and stays stale, and the task then
  exits with an error. It prints one line per test file, as in
  `tia: [12/749] test/foo_test.exs`, and the failures in full: the formatters
  configured in `test_helper.exs` are replaced by `Tia.Formatter` while
  recording. `--check` selects the stale test files plus those whose
  recorded sources appear in `git diff --name-only $(git merge-base BASE HEAD)`, and runs the whole
  suite when the map is missing or the globals moved.

  The project is compiled before the selection is computed, because a test
  file is also stale when the `.beam` file of a module it executed changed.
  That is how a change to a macro, a case template or a value inlined at
  compile time reaches only the test files that depend on it.

  ## Partitions

  The function counters behind the recording are global to the VM, so one VM
  records one test file at a time. `--partitions N` starts `N` `mix tia`
  processes that record in parallel and take the test files from one queue:
  each process asks for the next file when it finishes the one it has, so
  none of them waits while there is work left. The queue starts with the
  test files that have no recorded duration, in order, followed by the others
  from the slowest to the fastest, by the `ms` the map holds for them.

  The progress lines count over the whole run and carry the partition, as in
  `[2] tia: [12/749] test/foo_test.exs`. The output of each process is printed
  line by line, without ANSI escapes and with the same `[1] ` to `[N] `
  prefix, and the results are merged into the map at the end. The project is
  compiled once, before the processes start; they only load it.

  Each process gets `MIX_TEST_PARTITION` set to its number, from `1` to `N`,
  as `mix test --partitions` does. Use it to give each one its own database:

      config :my_app, MyApp.Repo,
        database: "my_app_test\#{System.get_env("MIX_TEST_PARTITION")}"

  Each process loads `test_helper.exs` and runs the `ExUnit.after_suite`
  callbacks once, with the totals of the test files it recorded. With one
  partition, or a single test file to record, everything runs in the current
  process and `MIX_TEST_PARTITION` is left alone.

  A process that dies takes with it the test file it was recording and the
  ones it had recorded since it last saved, at most 50 files: they count as
  failed and stay stale. The other processes go on with the rest of the queue.

  `--partitions auto` uses half of `System.schedulers_online/0`, at least
  one. Every partition starts the application, so with a database each one
  opens its own connection pool; see the README before raising the number.

  ## Options

    * `--base` - git ref to diff against, overrides the `:base` config
    * `--map` - map path, overrides the `:map` config
    * `--all` - record every test file again, even the current ones
    * `--only` - when recording, restrict to the test files matching this
      glob. With `--all`, only the entries of those test files are replaced
    * `--partitions` - when recording, the number of operating system
      processes to record with, or `auto`, overrides the `:partitions` config

  Arguments after the options are passed to `mix test` on `--check`. See
  `Tia.Config` for the `:tia` project options.
  """

  use Mix.Task

  @switches [
    base: :string,
    map: :string,
    check: :boolean,
    all: :boolean,
    dry_run: :boolean,
    only: :string,
    partitions: :string,
    worker: :boolean,
    out: :string,
    lock: :string
  ]
  @save_every 50
  @lock_variable "MIX_OS_CONCURRENCY_LOCK"
  # What starts a line a worker writes for the coordinator, never for the user.
  @signal "\0tia:"
  @no_stats %{total: 0, failures: 0, excluded: 0, skipped: 0}

  @impl true
  def run(args) do
    ensure_test_env(Mix.env())
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)
    Mix.ensure_application!(:crypto)

    if Keyword.get(opts, :worker, false) do
      work(Keyword.fetch!(opts, :out), config(opts), Keyword.get(opts, :lock))
    else
      Mix.Task.run("compile")
      coordinate(Tia.Cache.attach(config(opts)), opts, rest)
    end
  end

  # The workers hash only what they record, so the cache is for this side.
  defp coordinate(config, opts, rest) do
    stored = Tia.Map.read(config.map)

    if Keyword.get(opts, :check, false),
      do: check(stored, config, opts, rest),
      else: record(stored, config, opts)
  after
    flush_cache(config)
  end

  defp flush_cache(config) do
    case Tia.Cache.flush(config.cache) do
      :ok -> :ok
      {:error, reason} -> Mix.shell().error("tia: cannot write the hash cache: #{reason}")
    end
  end

  defp ensure_test_env(:test), do: :ok

  defp ensure_test_env(env) do
    Mix.raise(
      "mix tia must run in the test environment, got #{inspect(env)}. " <>
        "Add `def cli, do: [preferred_envs: [tia: :test]]` to mix.exs or set MIX_ENV=test"
    )
  end

  defp config(opts) do
    overrides = opts |> Keyword.take([:base, :map, :partitions]) |> Keyword.new(&override/1)

    [ebin: Mix.Project.compile_path()]
    |> Keyword.merge(Mix.Project.config()[:tia] || [])
    |> Keyword.merge(overrides)
    |> Tia.Config.new()
    |> ensure_partitions()
  end

  defp override({:partitions, "auto"}), do: {:partitions, :auto}

  defp override({:partitions, text}) do
    case Integer.parse(text) do
      {count, ""} -> {:partitions, count}
      _other -> {:partitions, text}
    end
  end

  defp override(pair), do: pair

  defp ensure_partitions(%Tia.Config{partitions: :auto} = config),
    do: %{config | partitions: max(1, div(System.schedulers_online(), 2))}

  defp ensure_partitions(%Tia.Config{partitions: count} = config)
       when is_integer(count) and count >= 1,
       do: config

  defp ensure_partitions(%Tia.Config{partitions: count}) do
    Mix.raise("tia: partitions must be a positive integer or auto, got #{inspect(count)}")
  end

  defp check({:ok, map}, config, opts, rest) do
    selection =
      case changed_files(config.base) do
        {:ok, files} -> Tia.Map.select(map, files, config)
        {:error, reason} -> {:all, reason}
      end

    # Before the tests run: they can take long, or take the VM down.
    flush_cache(config)
    execute(selection, opts, rest)
  end

  defp check(:error, _config, opts, rest), do: execute({:all, "no map"}, opts, rest)

  defp execute({:run, []}, _opts, _rest), do: Mix.shell().info("tia: no test file is affected")

  defp execute({:run, files}, opts, rest) do
    Mix.shell().info("tia: #{length(files)} test files")
    Enum.each(files, &Mix.shell().info("  #{&1}"))
    unless Keyword.get(opts, :dry_run, false), do: Mix.Task.run("test", files ++ rest)
  end

  defp execute({:all, reason}, opts, rest) do
    Mix.shell().info("tia: whole suite (#{reason})")
    unless Keyword.get(opts, :dry_run, false), do: Mix.Task.run("test", rest)
  end

  defp record(stored, config, opts) do
    stored = loaded_or_new(stored, config)
    # Read before the plan, which may empty the map.
    durations = Tia.Map.durations(stored)
    {map, selection} = recording_plan(stored, config, opts)
    flush_cache(config)

    case {selection, Keyword.get(opts, :dry_run, false)} do
      {{:run, []}, _} -> Mix.shell().info("tia: map is current")
      {{:run, files}, true} -> Mix.shell().info("tia: would record #{length(files)} test files")
      {{:run, files}, false} -> record_selected(map, files, config, durations)
    end
  end

  defp record_selected(map, files, config, durations) do
    case min(config.partitions, length(files)) do
      1 -> record_here(map, files, config)
      workers -> record_partitioned(map, slowest_first(files, durations), config, workers)
    end
  end

  # The longest test files go first, so that the last ones to be handed out
  # are short and the partitions finish close to each other. A test file with
  # no recorded duration may be long, so it goes before all of them.
  defp slowest_first(files, durations) do
    {timed, untimed} = Enum.split_with(files, &is_map_key(durations, &1))
    untimed ++ Enum.sort_by(timed, &Map.fetch!(durations, &1), :desc)
  end

  defp record_here(map, files, config) do
    total = length(files)

    {map, failed} =
      recording(config, &start_app/0, fn modules ->
        files
        |> Enum.with_index(1)
        |> Enum.reduce({{map, []}, @no_stats}, fn {file, index}, {{map, failed}, stats} ->
          Mix.shell().info("tia: [#{index}/#{total}] #{file}")
          {map, failed, stats} = record_file(map, failed, stats, file, modules, config)
          if rem(index, @save_every) == 0, do: Tia.Map.write(map, config.map)
          {{map, failed}, stats}
        end)
      end)

    Tia.Map.write(map, config.map)
    summary(files, failed, config, "")
  end

  defp summary(files, failed, config, suffix) do
    Mix.shell().info(
      "tia: recorded #{length(files) - length(failed)} of #{length(files)} test files " <>
        "into #{config.map}#{suffix}"
    )

    report(Enum.sort(failed))
  end

  # The worker side of `--partitions`. It tells the coordinator it is ready,
  # then records each test file that arrives as a line on its standard input
  # and answers with a `done` line. An empty line or the end of the input
  # means there is no more work: it writes its partial map to `out` and
  # leaves. It never raises for failing tests: the coordinator takes every
  # file it handed out that is absent from the partial map as failed.
  defp work(out, config, lock) do
    recording(config, fn -> start_worker_app(lock) end, fn modules ->
      signal("ready")
      serve(Tia.Map.new(config), @no_stats, 0, modules, config, out)
    end)

    :ok
  end

  defp serve(map, stats, count, modules, config, out) do
    case next_file() do
      nil ->
        Tia.Map.write(map, out)
        {map, stats}

      file ->
        {map, failed, stats} =
          try do
            record_file(map, [], stats, file, modules, config)
          catch
            # A test file that does not compile, for one. What was recorded
            # so far is saved, so only this file is lost with the worker.
            kind, reason ->
              Tia.Map.write(map, out)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        count = count + 1
        if rem(count, @save_every) == 0, do: Tia.Map.write(map, out)
        signal("done #{file} #{if failed == [], do: "ok", else: "failed"}")
        serve(map, stats, count, modules, config, out)
    end
  end

  defp next_file do
    with line when is_binary(line) <- IO.gets(:stdio, ""),
         file when file != "" <- String.trim_trailing(line, "\n") do
      file
    else
      _empty_eof_or_error -> nil
    end
  end

  defp signal(text), do: IO.write(:stdio, [@signal, text, "\n"])

  defp start_app, do: start_app([])

  defp start_app(args) do
    Mix.Task.run("app.config", args)
    modules = Tia.Recorder.start(Mix.Project.config()[:app])
    Mix.Task.run("app.start", args)
    modules
  end

  # The coordinator compiled the project before it started the workers, so a
  # worker only loads it. Mix still takes the lock of the build directory to
  # do that, even before this task runs when there are path dependencies, and
  # the workers would wait for each other. So the coordinator starts them
  # with the lock disabled, as `mix deps.partition` does with its own, and
  # the worker puts the variable back before the tests run, in case they
  # start Mix themselves.
  defp start_worker_app(lock) do
    start_app(["--no-compile", "--no-deps-check"])
  after
    if lock, do: System.put_env(@lock_variable, lock), else: System.delete_env(@lock_variable)
  end

  defp record_partitioned(map, queue, config, count) do
    dir = Path.join(Path.dirname(config.map), "partitions")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    try do
      workers = Map.new(1..count, &open_worker(&1, dir, config))
      state = %{queue: queue, total: length(queue), sent: 0, workers: workers, results: []}
      {map, failed} = state |> dispatch_loop() |> Enum.reduce({map, []}, &merge_partial/2)
      Tia.Map.write(map, config.map)
      summary(queue, failed, config, " (#{count} partitions)")
    after
      File.rm_rf!(dir)
    end
  end

  defp open_worker(index, dir, config) do
    out = Path.join(dir, "#{index}.json")

    port =
      Port.open({:spawn_executable, mix_executable()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        line: 4096,
        args: ["tia", "--worker", "--out", out, "--map", config.map] ++ lock_args(),
        env: [
          {~c"MIX_ENV", ~c"test"},
          {~c"MIX_TEST_PARTITION", ~c"#{index}"},
          {String.to_charlist(@lock_variable), ~c"false"}
        ]
      ])

    {port, %{index: index, out: out, pending: "", files: []}}
  end

  # The coordinator side of `--partitions`: one process owns every port, so
  # the queue needs no lock. A worker gets a test file when it says `ready`
  # and another one each time it says `done`, and an empty line once the
  # queue is empty. Returns, for each worker, the files it was given and the
  # partial map it left, plus the files nobody was left to take.
  defp dispatch_loop(%{workers: workers, queue: [], results: results})
       when map_size(workers) == 0,
       do: results

  defp dispatch_loop(%{workers: workers, queue: queue, results: results})
       when map_size(workers) == 0 do
    Mix.shell().error(
      "tia: every partition exited, #{length(queue)} test files were not recorded"
    )

    [{queue, :error} | results]
  end

  defp dispatch_loop(%{workers: workers} = state) do
    receive do
      {port, {:data, {:noeol, chunk}}} when is_map_key(workers, port) ->
        dispatch_loop(update_in(state.workers[port].pending, &(&1 <> chunk)))

      {port, {:data, {:eol, chunk}}} when is_map_key(workers, port) ->
        line = workers[port].pending <> chunk
        state = put_in(state.workers[port].pending, "")
        dispatch_loop(worker_line(state, port, String.split(line, @signal, parts: 2)))

      {port, {:exit_status, status}} when is_map_key(workers, port) ->
        dispatch_loop(worker_exit(state, port, status))
    end
  end

  defp worker_line(state, port, [text]) do
    Mix.shell().info("[#{state.workers[port].index}] " <> plain(text))
    state
  end

  # Something the tests wrote without a line break can come before a signal.
  defp worker_line(state, port, [text, signal]) do
    state = if text == "", do: state, else: worker_line(state, port, [text])

    case signal do
      "ready" -> hand_out(state, port)
      "done " <> _file_and_result -> hand_out(state, port)
      _unknown -> state
    end
  end

  defp hand_out(%{queue: []} = state, port) do
    tell(port, "")
    state
  end

  defp hand_out(%{queue: [file | queue], sent: sent} = state, port) do
    index = state.workers[port].index
    Mix.shell().info("[#{index}] tia: [#{sent + 1}/#{state.total}] #{file}")
    tell(port, file)
    state = update_in(state.workers[port].files, &[file | &1])
    %{state | queue: queue, sent: sent + 1}
  end

  # A worker that is already gone has its exit status on the way.
  defp tell(port, line) do
    Port.command(port, [line, "\n"])
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp worker_exit(state, port, status) do
    {worker, workers} = Map.pop!(state.workers, port)
    if worker.pending != "", do: Mix.shell().info("[#{worker.index}] " <> plain(worker.pending))

    if status != 0 do
      Mix.shell().error("tia: partition #{worker.index} exited with status #{status}")
    end

    result = {worker.files, Tia.Map.read(worker.out)}
    %{state | workers: workers, results: [result | state.results]}
  end

  defp lock_args do
    case System.get_env(@lock_variable) do
      nil -> []
      value -> ["--lock", value]
    end
  end

  defp mix_executable do
    System.find_executable("mix") || Mix.raise("tia: cannot find the mix executable in PATH")
  end

  defp plain(line), do: String.replace(line, ~r/\e\[[0-9;?]*[A-Za-z]/, "")

  # What a worker was given and did not leave in its partial map counts as
  # failed: the tests failed, or the worker died before it saved them.
  defp merge_partial({files, partial}, {%{"tests" => tests} = map, failed}) do
    recorded =
      case partial do
        {:ok, %{"tests" => entries}} -> Map.take(entries, files)
        :error -> %{}
      end

    missing = files -- Map.keys(recorded)
    tests = tests |> Map.merge(recorded) |> Map.drop(missing)
    {%{map | "tests" => tests}, missing ++ failed}
  end

  defp loaded_or_new({:ok, map}, _config), do: map
  defp loaded_or_new(:error, config), do: Tia.Map.new(config)

  defp recording_plan(map, config, opts) do
    all = Keyword.get(opts, :all, false)
    narrowed = Keyword.has_key?(opts, :only)

    case Tia.Map.plan(map, config) do
      # The globals moved: no entry can be trusted, with or without `--only`.
      {:all, _} ->
        {reset(map, config), {:run, only(Tia.Map.test_files(config), opts)}}

      {:run, _} when all and not narrowed ->
        {reset(map, config), {:run, Tia.Map.test_files(config)}}

      # `--all --only`: the entries of the other test files stay.
      {:run, _} when all ->
        {Tia.Map.prune(map, config), {:run, only(Tia.Map.test_files(config), opts)}}

      {:run, files} ->
        {Tia.Map.prune(map, config), {:run, only(files, opts)}}
    end
  end

  defp reset(map, config), do: %{map | "globals" => Tia.Map.globals(config), "tests" => %{}}

  defp only(files, opts) do
    case Keyword.get(opts, :only) do
      nil -> files
      glob -> Enum.filter(files, &(&1 in Path.wildcard(glob)))
    end
  end

  # Prepares the VM for recording, runs `fun` with the modules to watch and
  # returns the first element of what it gives back. The second one holds the
  # totals for the after_suite callbacks.
  defp recording(config, start_app, fun) do
    modules = Tia.Recorder.reject_ignored(start_app.(), config.ignore_modules)
    Mix.ensure_application!(:ex_unit)
    :ok = Application.ensure_loaded(:ex_unit)
    ExUnit.configure(autorun: false, max_cases: 1)
    Code.require_file(Path.join(config.root, "test/test_helper.exs"))
    # After the helper, which usually sets its own formatters in ExUnit.start/1.
    ExUnit.configure(formatters: [Tia.Formatter])

    # ExUnit.run/0 fires the after_suite callbacks on every run. They are held
    # back and fired once, with the totals, after all the test files ran.
    callbacks = Application.get_env(:ex_unit, :after_suite, [])
    Application.put_env(:ex_unit, :after_suite, [])

    {result, stats} =
      try do
        fun.(modules)
      after
        Application.put_env(:ex_unit, :after_suite, callbacks)
      end

    Enum.each(callbacks, & &1.(stats))
    result
  end

  defp record_file(map, failed, stats, file, modules, config) do
    started = System.monotonic_time(:millisecond)
    Tia.Recorder.reset(modules)
    Code.require_file(file)
    result = ExUnit.run()
    stats = add_stats(stats, result)

    case result do
      %{failures: 0} ->
        executed = Tia.Recorder.executed_modules(modules)
        sources = Tia.Recorder.sources(executed, config.root)
        names = Enum.map(executed, &Atom.to_string/1)
        ms = System.monotonic_time(:millisecond) - started
        {Tia.Map.put(map, config, file, sources, names, ms), failed, stats}

      %{failures: _} ->
        {Tia.Map.delete(map, file), [file | failed], stats}
    end
  end

  defp add_stats(stats, result) do
    Map.new(stats, fn {key, sum} -> {key, sum + Map.get(result, key, 0)} end)
  end

  defp report([]), do: :ok

  defp report(failed) do
    Mix.raise("tia: not recorded, tests failed:\n" <> Enum.map_join(failed, "\n", &"  #{&1}"))
  end

  defp changed_files(base) do
    with {:ok, [sha | _]} <- git(["merge-base", base, "HEAD"]),
         {:ok, tracked} <- git(["diff", "--name-only", sha]),
         {:ok, untracked} <- git(["ls-files", "--others", "--exclude-standard"]) do
      {:ok, Enum.uniq(tracked ++ untracked)}
    else
      {:error, reason} -> {:error, "cannot diff against #{base}: #{reason}"}
      {:ok, []} -> {:error, "cannot diff against #{base}: no merge base with HEAD"}
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {out, _} -> {:error, out |> String.split("\n", trim: true) |> List.first("git failed")}
    end
  end
end
