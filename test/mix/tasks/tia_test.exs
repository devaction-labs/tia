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
        [app: :fixture, version: "0.1.0", deps: [{:tia, path: #{inspect(@tia_path)}, only: [:dev, :test], runtime: false}]]
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
             "test/alpha_test.exs" => %{"sources" => ["lib/alpha.ex"]},
             "test/beta_test.exs" => %{"sources" => ["lib/beta.ex"]},
             "test/embedded_test.exs" => %{"sources" => ["lib/embedded.ex", "priv/data.txt"]}
           } = tests(root)
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
