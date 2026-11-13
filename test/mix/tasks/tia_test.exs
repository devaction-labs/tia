defmodule Mix.Tasks.TiaTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @tia_path Path.expand("../../..", __DIR__)

  setup %{tmp_dir: root} do
    write(root, "mix.exs", """
    defmodule Fixture.MixProject do
      use Mix.Project

      def cli, do: [preferred_envs: [tia: :test]]

      def project do
        [
          app: :fixture,
          version: "0.1.0",
          elixirc_paths: ["lib", "test/support"],
          deps: [{:tia, path: #{inspect(@tia_path)}, only: [:dev, :test], runtime: false}]
        ]
      end
    end
    """)

    write(root, "lib/alpha.ex", "defmodule Alpha, do: def(value, do: 1)")
    write(root, "lib/beta.ex", "defmodule Beta, do: def(value, do: 2)")
    write(root, "lib/untouched.ex", "defmodule Untouched, do: def(value, do: 3)")
    write(root, "priv/data.txt", "hello")

    write(root, "lib/embedded.ex", """
    defmodule Embedded do
      @external_resource "priv/data.txt"
      def value, do: unquote(File.read!("priv/data.txt"))
    end
    """)

    write(root, "test/test_helper.exs", "ExUnit.start()")
    write(root, "test/alpha_test.exs", test_module("AlphaTest", "Alpha.value() == 1"))
    write(root, "test/beta_test.exs", test_module("BetaTest", "Beta.value() == 2"))
    write(root, "test/embedded_test.exs", test_module("EmbeddedTest", "Embedded.value()"))

    %{root: root}
  end

  test "records each test file with the sources it ran and nothing else", %{root: root} do
    {output, 0} = mix(root, ["tia"])

    assert output =~ "recorded 3 of 3"
    refute output =~ "0 tests"

    assert %{
             "test/alpha_test.exs" => %{
               "sources" => ["lib/alpha.ex"],
               "modules" => ["Elixir.Alpha"]
             },
             "test/beta_test.exs" => %{"sources" => ["lib/beta.ex"], "modules" => ["Elixir.Beta"]},
             "test/embedded_test.exs" => %{
               "sources" => ["lib/embedded.ex", "priv/data.txt"],
               "modules" => ["Elixir.Embedded"]
             }
           } = tests(root)
  end

  test "changing a macro makes stale only the tests that ran a module expanding it", %{
    root: root
  } do
    write(root, "lib/macros.ex", "defmodule Macros, do: defmacro(v(), do: 1)")

    write(root, "lib/user_of_macro.ex", """
    defmodule UserOfMacro do
      require Macros
      def value, do: Macros.v()
    end
    """)

    write(root, "test/user_of_macro_test.exs", test_module("UserTest", "UserOfMacro.value()"))
    {output, 0} = mix(root, ["tia"])
    assert output =~ "recorded 4 of 4"

    assert %{"sources" => ["lib/user_of_macro.ex"], "modules" => ["Elixir.UserOfMacro"]} =
             tests(root)["test/user_of_macro_test.exs"]

    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "map is current"

    write(root, "lib/macros.ex", "defmodule Macros, do: defmacro(v(), do: 20 + 2)")
    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "would record 1 test files"

    assert {output, 0} = mix(root, ["tia", "--check", "--dry-run", "--base", "HEAD"], git: true)
    assert output =~ "1 test files"
    assert output =~ "test/user_of_macro_test.exs"
    refute output =~ "whole suite"

    assert {output, 0} = mix(root, ["tia"])
    assert output =~ "recorded 1 of 1"
  end

  test "changing a value inlined at compile time reaches the tests of the module embedding it",
       %{root: root} do
    write(root, "lib/limits.ex", "defmodule Limits, do: def(limit, do: 10)")

    write(root, "lib/inliner.ex", """
    defmodule Inliner do
      @limit Limits.limit()
      def value, do: @limit
    end
    """)

    write(root, "test/inliner_test.exs", test_module("InlinerTest", "Inliner.value()"))
    {_, 0} = mix(root, ["tia"])
    assert %{"sources" => ["lib/inliner.ex"]} = tests(root)["test/inliner_test.exs"]

    write(root, "lib/limits.ex", "defmodule Limits, do: def(limit, do: 2000)")
    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "would record 1 test files"
  end

  test "changing a case template makes stale only the tests that use it", %{root: root} do
    write(root, "test/support/data_case.ex", data_case(1))

    write(root, "test/templated_test.exs", """
    defmodule TemplatedTest do
      use Fixture.DataCase
      test "it", do: assert(helper() == Alpha.value())
    end
    """)

    {output, 0} = mix(root, ["tia"])
    assert output =~ "recorded 4 of 4"

    assert %{
             "sources" => ["lib/alpha.ex", "test/support/data_case.ex"],
             "modules" => ["Elixir.Alpha", "Elixir.Fixture.DataCase"]
           } = tests(root)["test/templated_test.exs"]

    refute "Elixir.Fixture.DataCase" in tests(root)["test/alpha_test.exs"]["modules"]

    write(root, "test/support/data_case.ex", data_case("2 - 1"))
    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "would record 1 test files"

    assert {output, 0} = mix(root, ["tia"])
    assert output =~ "recorded 1 of 1"
  end

  test "records again only what a change made stale", %{root: root} do
    {_, 0} = mix(root, ["tia"])

    write(root, "lib/alpha.ex", "defmodule Alpha, do: def(value, do: 1 + 0)")
    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "would record 1 test files"

    write(root, "lib/alpha.ex", "defmodule Alpha, do: def(value, do: 1)")
    write(root, "priv/data.txt", "changed")
    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "would record 1 test files"
  end

  test "a failing test file is left out of the map and fails the task", %{root: root} do
    write(root, "test/beta_test.exs", test_module("BetaTest", "Beta.value() == :nope"))

    assert {output, status} = mix(root, ["tia"])

    assert status != 0
    assert output =~ "test/beta_test.exs"
    refute Map.has_key?(tests(root), "test/beta_test.exs")
    assert Map.has_key?(tests(root), "test/alpha_test.exs")
  end

  test "--check runs what the diff can reach and nothing else", %{root: root} do
    {_, 0} = mix(root, ["tia"])
    assert {output, 0} = mix(root, ["tia", "--check", "--dry-run", "--base", "HEAD"], git: true)
    assert output =~ "no test file is affected"

    write(root, "lib/beta.ex", "defmodule Beta, do: def(value, do: 1 + 1)")
    assert {output, 0} = mix(root, ["tia", "--check", "--base", "HEAD"], git: true)
    assert output =~ "1 test files"
    assert output =~ "test/beta_test.exs"
    refute output =~ "test/alpha_test.exs"
  end

  test "after_suite callbacks run once, after every test file is recorded", %{root: root} do
    log = Path.join(root, "after_suite.log")

    write(root, "test/test_helper.exs", """
    ExUnit.start()
    ExUnit.after_suite(fn stats -> File.write!(#{inspect(log)}, "total=\#{stats.total}\\n", [:append]) end)
    """)

    assert {_, 0} = mix(root, ["tia"])
    assert File.read!(log) == "total=3\n"
  end

  test "--check falls back to the whole suite when the base cannot be diffed", %{root: root} do
    {_, 0} = mix(root, ["tia"])
    init_git(root)

    assert {output, 0} = mix(root, ["tia", "--check", "--dry-run", "--base", "nao-existe"])
    assert output =~ "whole suite (cannot diff against nao-existe:"
  end

  test "--check diffs against the merge base, not the tip of an advanced base", %{root: root} do
    {_, 0} = mix(root, ["tia"])
    init_git(root)
    git!(root, ["branch", "base"])
    git!(root, ["checkout", "-q", "base"])
    write(root, "lib/alpha.ex", "defmodule Alpha, do: def(value, do: 1 + 0)")
    git!(root, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "advance"])
    git!(root, ["checkout", "-q", "-"])

    assert {output, 0} = mix(root, ["tia", "--check", "--dry-run", "--base", "base"])
    assert output =~ "no test file is affected"
  end

  test "--partitions records the same map as a single process", %{root: root} do
    assert {output, 0} = mix(root, ["tia", "--partitions", "2"])
    assert output =~ "recorded 3 of 3"
    assert output =~ "(2 partitions)"
    assert output =~ ~r/^\[1\] /m
    assert output =~ ~r/^\[2\] /m
    partitioned = tests(root)
    refute File.exists?(Path.join(root, ".tia/partitions"))

    File.rm!(Path.join(root, ".tia/map.json"))
    assert {_, 0} = mix(root, ["tia"])
    single = tests(root)

    assert Map.keys(partitioned) == Map.keys(single)

    for {file, entry} <- single do
      assert Enum.sort(partitioned[file]["sources"]) == Enum.sort(entry["sources"])
      assert Enum.sort(partitioned[file]["modules"]) == Enum.sort(entry["modules"])
      assert partitioned[file]["hash"] == entry["hash"]
    end

    assert {output, 0} = mix(root, ["tia", "--dry-run", "--partitions", "2"])
    assert output =~ "map is current"
  end

  test "--all --only replaces the selected entries and keeps the others", %{root: root} do
    {_, 0} = mix(root, ["tia"])
    before = tests(root)

    write(root, "test/alpha_test.exs", test_module("AlphaTest", "Alpha.value() + Beta.value()"))
    assert {output, 0} = mix(root, ["tia", "--all", "--only", "test/alpha*_test.exs"])
    assert output =~ "recorded 1 of 1"

    recorded = tests(root)
    assert Map.keys(recorded) == Map.keys(before)
    assert recorded["test/beta_test.exs"] == before["test/beta_test.exs"]
    assert recorded["test/embedded_test.exs"] == before["test/embedded_test.exs"]
    assert recorded["test/alpha_test.exs"]["modules"] == ["Elixir.Alpha", "Elixir.Beta"]

    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "map is current"

    # When the globals moved no entry can be kept.
    write(root, "config/config.exs", "import Config")
    assert {output, 0} = mix(root, ["tia", "--all", "--only", "test/alpha*_test.exs"])
    assert output =~ "recorded 1 of 1"
    assert Map.keys(tests(root)) == ["test/alpha_test.exs"]
  end

  test "recording prints a line per test file and the failures, not the ExUnit summary", %{
    root: root
  } do
    write(root, "test/beta_test.exs", test_module("BetaTest", "Beta.value() == :nope"))

    write(root, "test/test_helper.exs", """
    ExUnit.start(formatters: [ExUnit.CLIFormatter], trace: true)
    """)

    assert {output, status} = mix(root, ["tia"])
    assert status != 0

    assert output =~ "tia: [1/3] test/alpha_test.exs\n"
    assert output =~ "tia: [2/3] test/beta_test.exs\n"
    assert output =~ "tia: [3/3] test/embedded_test.exs\n"

    assert output =~ "1) test it (BetaTest)"
    assert output =~ "test/beta_test.exs:3"
    assert output =~ "Assertion with == failed"
    assert output =~ "right: :nope"

    refute output =~ "Running ExUnit"
    refute output =~ "Finished in"
    refute output =~ "Result:"
    refute output =~ " passed"
    refute output =~ "\e["
  end

  test "workers do not compile again and their lines come without ANSI escapes", %{root: root} do
    # The workers start with the build lock of Mix disabled and give it back to the tests.
    write(
      root,
      "test/alpha_test.exs",
      test_module(
        "AlphaTest",
        ~s|Alpha.value() == 1 and System.get_env("MIX_OS_CONCURRENCY_LOCK") == nil|
      )
    )

    assert {output, 0} = mix(root, ["tia", "--partitions", "3"])

    assert output =~ "recorded 3 of 3"
    refute output =~ "Waiting for lock"
    refute output =~ "\e["
    # The progress counts over the whole run, in the order of the queue.
    assert output =~ ~r/^\[[123]\] tia: \[1\/3\] test\/alpha_test.exs$/m
    assert output =~ ~r/^\[[123]\] tia: \[2\/3\] test\/beta_test.exs$/m
    assert output =~ ~r/^\[[123]\] tia: \[3\/3\] test\/embedded_test.exs$/m
    assert [_once] = Regex.scan(~r/Generated fixture app/, output)
    refute output =~ "tia:ready"
    refute output =~ "tia:done"
    refute output =~ <<0>>

    for line <- String.split(output, "\n"), line =~ ~r/^\[\d\] / do
      assert line =~ ~r/^\[\d\] tia: \[/
    end
  end

  test ":ignore_modules keeps modules out of the map", %{root: root} do
    write(root, "lib/beta.ex", "defmodule Beta, do: def(value, do: Beta.Inner.value())")

    write(
      root,
      "lib/beta_inner.ex",
      "defmodule Beta.Inner, do: def(value, do: Alpha.value() + 1)"
    )

    configure(root, ~s(ignore_modules: ["Beta.Inn", Alpha]))

    assert {_, 0} = mix(root, ["tia"])

    assert %{"modules" => ["Elixir.Beta"], "sources" => ["lib/beta.ex"]} =
             tests(root)["test/beta_test.exs"]

    assert %{"modules" => [], "sources" => []} = tests(root)["test/alpha_test.exs"]
  end

  test "--partitions leaves a failing test file out, records the others and fails the task",
       %{root: root} do
    {_, 0} = mix(root, ["tia"])
    write(root, "test/beta_test.exs", test_module("BetaTest", "Beta.value() == :nope"))
    write(root, "test/alpha_test.exs", test_module("AlphaTest", "Alpha.value() != 2"))

    assert {output, status} = mix(root, ["tia", "--partitions", "2"])

    assert status != 0
    assert output =~ "recorded 1 of 2"
    assert output =~ "not recorded, tests failed:\n  test/beta_test.exs"
    refute Map.has_key?(tests(root), "test/beta_test.exs")
    assert Map.has_key?(tests(root), "test/alpha_test.exs")
    assert Map.has_key?(tests(root), "test/embedded_test.exs")
    refute File.exists?(Path.join(root, ".tia/partitions"))

    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "would record 1 test files"
  end

  test "each partition gets its own MIX_TEST_PARTITION, from the config too", %{root: root} do
    # Each of the two waits for the other to start, so they need two partitions.
    for {name, module, other} <- [{"alpha", "AlphaTest", "beta"}, {"beta", "BetaTest", "alpha"}] do
      write(root, "test/#{name}_test.exs", """
      defmodule #{module} do
        use ExUnit.Case

        test "it" do
          File.write!("partition_#{name}.txt", System.get_env("MIX_TEST_PARTITION"))
          assert Enum.any?(1..600, fn _ ->
                   File.exists?("partition_#{other}.txt") or Process.sleep(100) != :ok
                 end)
        end
      end
      """)
    end

    configure(root, "partitions: 2")

    assert {output, 0} = mix(root, ["tia"])
    assert output =~ "recorded 3 of 3"

    partitions =
      for name <- ["alpha", "beta"], do: File.read!(Path.join(root, "partition_#{name}.txt"))

    assert Enum.sort(partitions) == ["1", "2"]
    refute File.exists?(Path.join(root, ".tia/partitions"))
  end

  test "an idle partition takes the next test file while another one is busy", %{root: root} do
    quick = for index <- 1..5, do: "quick_#{index}"

    for name <- quick do
      write(root, "test/#{name}_test.exs", """
      defmodule #{Macro.camelize(name)}Test do
        use ExUnit.Case
        test "it", do: File.write!("ran_#{name}.txt", "")
      end
      """)
    end

    # First in the queue, and it only ends after every other test file ran:
    # with a fixed split, its partition would hold some of them back.
    write(root, "test/aaa_slow_test.exs", """
    defmodule AaaSlowTest do
      use ExUnit.Case
      @moduletag timeout: 120_000

      test "it" do
        assert Enum.any?(1..600, fn _ ->
                 Enum.all?(#{inspect(quick)}, &File.exists?("ran_\#{&1}.txt")) or
                   Process.sleep(100) != :ok
               end)
      end
    end
    """)

    assert {output, 0} = mix(root, ["tia", "--partitions", "2"])
    assert output =~ "recorded 9 of 9"

    handed = handed_out(output)
    assert Enum.map(handed, &elem(&1, 1)) == Enum.to_list(1..9)
    assert [{slow, 1, "test/aaa_slow_test.exs"} | others] = handed
    assert length(others) == 8
    assert Enum.all?(others, fn {partition, _index, _file} -> partition != slow end)

    # The slow file took at least as long as all the others it waited for.
    recorded = tests(root)
    slow_ms = recorded["test/aaa_slow_test.exs"]["ms"]
    assert Enum.all?(quick, &(recorded["test/#{&1}_test.exs"]["ms"] <= slow_ms))
  end

  test "records how long each test file took and hands out the slowest first", %{root: root} do
    write(root, "test/zzz_sleepy_test.exs", """
    defmodule ZzzSleepyTest do
      use ExUnit.Case
      test "it", do: Process.sleep(400)
    end
    """)

    assert {_, 0} = mix(root, ["tia"])
    recorded = tests(root)
    assert Enum.all?(recorded, fn {_file, entry} -> is_integer(entry["ms"]) end)
    assert recorded["test/zzz_sleepy_test.exs"]["ms"] >= 400
    assert recorded["test/alpha_test.exs"]["ms"] < 400

    map_path = Path.join(root, ".tia/map.json")
    lines = map_path |> File.read!() |> String.split("\n")
    assert Enum.count(lines, &(&1 =~ ~s("ms":))) == 4
    assert Enum.count(lines, &(&1 =~ "_test.exs")) == 4

    # Last by name, first by duration. `--all` empties the map but keeps the order.
    assert {output, 0} = mix(root, ["tia", "--all", "--partitions", "2"])
    assert [{_, 1, "test/zzz_sleepy_test.exs"} | _] = handed_out(output)
    assert tests(root)["test/zzz_sleepy_test.exs"]["ms"] >= 400

    # A map without durations is still current, and keeps the order of the names.
    File.write!(map_path, Regex.replace(~r/"ms":\d+,/, File.read!(map_path), ""))
    refute File.read!(map_path) =~ ~s("ms")
    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "map is current"

    assert {output, 0} = mix(root, ["tia", "--all", "--partitions", "2"])
    assert [{_, 1, "test/alpha_test.exs"} | _] = handed_out(output)

    # A test file with no duration goes before the ones that have one.
    write(root, "test/new_test.exs", test_module("NewTest", "Beta.value() == 2"))
    write(root, "lib/alpha.ex", "defmodule Alpha, do: def(value, do: 2 - 1)")

    write(root, "test/zzz_sleepy_test.exs", """
    defmodule ZzzSleepyTest do
      use ExUnit.Case
      test "it", do: Process.sleep(401)
    end
    """)

    assert {output, 0} = mix(root, ["tia", "--partitions", "3"])

    assert [
             {_, 1, "test/new_test.exs"},
             {_, 2, "test/zzz_sleepy_test.exs"},
             {_, 3, "test/alpha_test.exs"}
           ] = handed_out(output)
  end

  test "a partition that dies loses only its own test files", %{root: root} do
    # The first of the queue takes its VM down at once. The other partition
    # records the rest and then meets a test file that does not compile.
    write(root, "test/aaa_killer_test.exs", """
    defmodule AaaKillerTest do
      use ExUnit.Case
      test "it", do: System.halt(3)
    end
    """)

    write(root, "test/zzz_broken_test.exs", "defmodule ZzzBrokenTest do\n  def broken(\nend\n")

    assert {output, status} = mix(root, ["tia", "--partitions", "2"])
    assert status != 0

    assert [
             {killed, 1, "test/aaa_killer_test.exs"},
             {alive, 2, "test/alpha_test.exs"},
             {alive, 3, "test/beta_test.exs"},
             {alive, 4, "test/embedded_test.exs"},
             {alive, 5, "test/zzz_broken_test.exs"}
           ] = handed_out(output)

    assert killed != alive
    assert output =~ "tia: partition #{killed} exited with status 3"
    assert output =~ "tia: partition #{alive} exited with status 1"
    assert output =~ "recorded 3 of 5"

    assert output =~
             "not recorded, tests failed:\n  test/aaa_killer_test.exs\n  test/zzz_broken_test.exs"

    assert Map.keys(tests(root)) ==
             ["test/alpha_test.exs", "test/beta_test.exs", "test/embedded_test.exs"]

    refute File.exists?(Path.join(root, ".tia/partitions"))
  end

  test "when every partition dies the test files left in the queue are reported", %{root: root} do
    write(root, "test/test_helper.exs", """
    if System.get_env("MIX_TEST_PARTITION"), do: System.halt(5)
    ExUnit.start()
    """)

    assert {output, status} = mix(root, ["tia", "--partitions", "2"])
    assert status != 0
    assert output =~ "tia: partition 1 exited with status 5"
    assert output =~ "tia: partition 2 exited with status 5"
    assert output =~ "every partition exited, 3 test files were not recorded"
    assert output =~ "recorded 0 of 3"
    assert handed_out(output) == []
  end

  test "--partitions auto and the :auto config use half of the schedulers", %{root: root} do
    count = min(3, max(1, div(System.schedulers_online(), 2)))
    suffix = if count == 1, do: ".tia/map.json\n", else: "(#{count} partitions)\n"

    assert {output, 0} = mix(root, ["tia", "--partitions", "auto"])
    assert output =~ "recorded 3 of 3"
    assert String.ends_with?(output, suffix)

    configure(root, "partitions: :auto")
    assert {output, 0} = mix(root, ["tia", "--all"])
    assert output =~ "recorded 3 of 3"
    assert String.ends_with?(output, suffix)

    for value <- ["0", "many"] do
      assert {output, status} = mix(root, ["tia", "--partitions", value])
      assert status != 0
      assert output =~ "partitions must be a positive integer or auto"
    end
  end

  test "keeps a local hash cache, survives a damaged one and can do without it", %{root: root} do
    cache = Path.join(root, ".tia/cache.bin")
    assert {_, 0} = mix(root, ["tia"])

    # Files modified in the last two seconds are not cached.
    Process.sleep(2100)
    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "map is current"
    assert {:tia_cache, _version, entries} = cache |> File.read!() |> :erlang.binary_to_term()
    assert is_map_key(entries, {:file, Path.join(root, "lib/alpha.ex")})
    assert Enum.any?(entries, &match?({{{:beam, ^root}, _path}, _value}, &1))
    assert Path.wildcard(Path.join(root, ".tia/*.tmp")) == []

    write(root, "lib/alpha.ex", "defmodule Alpha, do: def(value, do: 3 - 2)")
    assert {output, 0} = mix(root, ["tia", "--dry-run"])
    assert output =~ "would record 1 test files"

    File.write!(cache, "not a cache")
    assert {output, 0} = mix(root, ["tia"])
    assert output =~ "recorded 1 of 1"

    File.rm!(cache)
    configure(root, "cache: false")
    Process.sleep(2100)
    assert {output, 0} = mix(root, ["tia", "--all"])
    assert output =~ "recorded 3 of 3"
    refute File.exists?(cache)
  end

  test "outside the test environment it refuses with the fix", %{root: root} do
    assert {output, status} =
             System.cmd("mix", ["tia"],
               cd: root,
               stderr_to_stdout: true,
               env: [{"MIX_ENV", "dev"}]
             )

    assert status != 0
    assert output =~ "preferred_envs"
  end

  defp data_case(value) do
    """
    defmodule Fixture.DataCase do
      use ExUnit.CaseTemplate

      using do
        quote do
          def helper, do: #{value}
        end
      end
    end
    """
  end

  # Sets the `:tia` options of the fixture project.
  defp configure(root, options) do
    mix_exs = File.read!(Path.join(root, "mix.exs"))

    write(
      root,
      "mix.exs",
      String.replace(mix_exs, "app: :fixture,", "tia: [#{options}], app: :fixture,")
    )
  end

  # The test files the coordinator handed out, as `{partition, position, file}`.
  defp handed_out(output) do
    for [_, partition, index, file] <-
          Regex.scan(~r/^\[(\d+)\] tia: \[(\d+)\/\d+\] (.+)$/m, output),
        do: {String.to_integer(partition), String.to_integer(index), file}
  end

  defp test_module(name, assertion) do
    """
    defmodule #{name} do
      use ExUnit.Case
      test "it", do: assert(#{assertion})
    end
    """
  end

  defp mix(root, args, opts \\ []) do
    if opts[:git], do: init_git(root)
    System.cmd("mix", args, cd: root, stderr_to_stdout: true, env: [{"MIX_ENV", nil}])
  end

  defp init_git(root) do
    File.write!(Path.join(root, ".gitignore"), "_build\ndeps\n")

    for args <- [
          ["init", "-q"],
          ["add", "-A"],
          ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base", "--allow-empty"]
        ] do
      {_, 0} = System.cmd("git", args, cd: root)
    end
  end

  defp git!(root, args), do: {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)

  defp tests(root) do
    {:ok, map} = Tia.Map.read(Path.join(root, ".tia/map.json"))
    map["tests"]
  end

  defp write(root, path, body) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
  end
end
