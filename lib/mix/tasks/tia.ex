defmodule Mix.Tasks.Tia do
  @shortdoc "Runs the test files a change can affect and keeps the TIA map current"
  @moduledoc """
  Test impact analysis driven by a recorded map (`.tia/map.json` by default).

      mix tia                  # record the stale test files, update the map
      mix tia --all            # record every test file
      mix tia --check          # CI: run the affected test files, change nothing
      mix tia --dry-run        # only print the selection

  The task must run in the test environment. As it comes from a dependency,
  Mix cannot know that by itself, so declare it in `mix.exs`:

      def cli, do: [preferred_envs: [tia: :test]]

  Recording runs each test file on its own and stores the files it executed. A
  file whose tests fail is not recorded and stays stale, and the task then
  exits with an error. `--check` selects the stale test files plus those whose
  recorded sources appear in `git diff --name-only BASE`, and runs the whole
  suite when the map is missing or the globals moved.

  ## Options

    * `--base` - git ref to diff against, overrides the `:base` config
    * `--map` - map path, overrides the `:map` config
    * `--only` - when recording, restrict to the test files matching this glob

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
    only: :string
  ]
  @save_every 50

  @impl true
  def run(args) do
    ensure_test_env(Mix.env())
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)
    Mix.ensure_application!(:crypto)
    config = config(opts)
    stored = Tia.Map.read(config.map)

    case Keyword.get(opts, :check, false) do
      true -> check(stored, config, opts, rest)
      false -> record(stored, config, opts)
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
    overrides = Keyword.take(opts, [:base, :map])
    Tia.Config.new(Keyword.merge(Mix.Project.config()[:tia] || [], overrides))
  end

  defp check({:ok, map}, config, opts, rest),
    do: execute(Tia.Map.select(map, changed_files(config.base), config), opts, rest)

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
    {map, selection} = stored |> loaded_or_new(config) |> recording_plan(config, opts)

    case {selection, Keyword.get(opts, :dry_run, false)} do
      {{:run, []}, _} -> Mix.shell().info("tia: map is current")
      {{:run, files}, true} -> Mix.shell().info("tia: would record #{length(files)} test files")
      {{:run, files}, false} -> record_files(map, files, config)
    end
  end

  defp loaded_or_new({:ok, map}, _config), do: map
  defp loaded_or_new(:error, config), do: Tia.Map.new(config)

  defp recording_plan(map, config, opts) do
    case {Keyword.get(opts, :all, false), Tia.Map.plan(map, config)} do
      {true, _} -> {reset(map, config), {:run, only(Tia.Map.test_files(config), opts)}}
      {false, {:all, _}} -> {reset(map, config), {:run, only(Tia.Map.test_files(config), opts)}}
      {false, {:run, files}} -> {Tia.Map.prune(map, config), {:run, only(files, opts)}}
    end
  end

  defp reset(map, config), do: %{map | "globals" => Tia.Map.globals(config), "tests" => %{}}

  defp only(files, opts) do
    case Keyword.get(opts, :only) do
      nil -> files
      glob -> Enum.filter(files, &(&1 in Path.wildcard(glob)))
    end
  end

  defp record_files(map, files, config) do
    Mix.Task.run("app.config")
    modules = Tia.Recorder.start(Mix.Project.config()[:app])
    Mix.Task.run("app.start")
    Mix.ensure_application!(:ex_unit)
    :ok = Application.ensure_loaded(:ex_unit)
    ExUnit.configure(autorun: false, max_cases: 1)
    Code.require_file("test/test_helper.exs")

    {map, failed} =
      files
      |> Enum.with_index(1)
      |> Enum.reduce({map, []}, fn {file, index}, {map, failed} ->
        {map, failed} = record_file(map, failed, file, modules, config)
        if rem(index, @save_every) == 0, do: Tia.Map.write(map, config.map)
        {map, failed}
      end)

    Tia.Map.write(map, config.map)

    Mix.shell().info(
      "tia: recorded #{length(files) - length(failed)} of #{length(files)} test files " <>
        "into #{config.map}"
    )

    report(failed)
  end

  defp record_file(map, failed, file, modules, config) do
    Tia.Recorder.reset(modules)
    Code.require_file(file)

    case ExUnit.run() do
      %{failures: 0} ->
        sources = Tia.Recorder.executed_sources(modules, config.root)
        {Tia.Map.put(map, config, file, sources), failed}

      %{failures: _} ->
        {Tia.Map.delete(map, file), [file | failed]}
    end
  end

  defp report([]), do: :ok

  defp report(failed) do
    Mix.raise("tia: not recorded, tests failed:\n" <> Enum.map_join(failed, "\n", &"  #{&1}"))
  end

  defp changed_files(base) do
    tracked = git(["diff", "--name-only", base])
    untracked = git(["ls-files", "--others", "--exclude-standard"])
    Enum.uniq(tracked ++ untracked)
  end

  defp git(args) do
    {out, 0} = System.cmd("git", args)
    String.split(out, "\n", trim: true)
  end
end
