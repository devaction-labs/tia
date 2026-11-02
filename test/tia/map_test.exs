defmodule Tia.MapTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    write(root, "mix.exs", "m")
    write(root, "mix.lock", "l")
    write(root, "config/config.exs", "c")
    write(root, "lib/a.ex", "defmodule A, do: nil")
    write(root, "lib/b.ex", "defmodule B, do: nil")
    write(root, "test/a_test.exs", "a")
    write(root, "test/b_test.exs", "b")
    config = Tia.Config.new(root: root)

    map =
      config
      |> Tia.Map.new()
      |> Tia.Map.put(config, "test/a_test.exs", ["lib/a.ex"])
      |> Tia.Map.put(config, "test/b_test.exs", ["lib/b.ex"])

    %{root: root, map: map, config: config}
  end

  defp write(root, path, body) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
  end

  test "a freshly recorded map has nothing stale", %{root: root, map: map} do
    assert Tia.Map.plan(map, Tia.Config.new(root: root)) == {:run, []}
  end

  test "changing a recorded source makes only its tests stale", %{root: root, map: map} do
    write(root, "lib/a.ex", "defmodule A, do: 1")

    assert Tia.Map.plan(map, Tia.Config.new(root: root)) == {:run, ["test/a_test.exs"]}
  end

  test "changing the test file itself makes it stale", %{root: root, map: map} do
    write(root, "test/b_test.exs", "changed")

    assert Tia.Map.plan(map, Tia.Config.new(root: root)) == {:run, ["test/b_test.exs"]}
  end

  test "a deleted source makes its tests stale", %{root: root, map: map} do
    File.rm!(Path.join(root, "lib/b.ex"))

    assert Tia.Map.plan(map, Tia.Config.new(root: root)) == {:run, ["test/b_test.exs"]}
  end

  test "a test file with no entry is stale, so a renamed file cannot slip through", %{
    root: root,
    map: map
  } do
    File.rename!(Path.join(root, "test/a_test.exs"), Path.join(root, "test/renamed_test.exs"))

    assert Tia.Map.plan(map, Tia.Config.new(root: root)) == {:run, ["test/renamed_test.exs"]}
  end

  test "moving the globals makes everything stale", %{root: root, map: map} do
    write(root, "mix.lock", "new lock")

    assert {:all, _reason} = Tia.Map.plan(map, Tia.Config.new(root: root))
  end

  test "a file that defines macros is a global", %{root: root} do
    write(root, "lib/macros.ex", "defmacro x, do: nil")
    map = Tia.Map.new(Tia.Config.new(root: root))
    write(root, "lib/macros.ex", "defmacro y, do: nil")

    assert {:all, _reason} = Tia.Map.plan(map, Tia.Config.new(root: root))
  end

  test "select adds the tests whose sources are in the diff to the stale ones", %{
    root: root,
    map: map
  } do
    write(root, "test/b_test.exs", "changed")

    assert Tia.Map.select(map, ["lib/a.ex"], Tia.Config.new(root: root)) ==
             {:run, ["test/a_test.exs", "test/b_test.exs"]}
  end

  test "select runs nothing when the diff touches no recorded source", %{root: root, map: map} do
    assert Tia.Map.select(map, ["README.md"], Tia.Config.new(root: root)) == {:run, []}
  end

  test "delete leaves the test file stale", %{root: root, map: map} do
    map = Tia.Map.delete(map, "test/a_test.exs")

    assert Tia.Map.plan(map, Tia.Config.new(root: root)) == {:run, ["test/a_test.exs"]}
  end

  test "write and read round-trip with one test file per line", %{root: root, map: map} do
    path = Path.join(root, ".tia/map.json")

    assert :ok = Tia.Map.write(map, path)
    assert {:ok, ^map} = Tia.Map.read(path)

    assert path
           |> File.read!()
           |> String.split("\n")
           |> Enum.count(&String.contains?(&1, "_test.exs")) == 2
  end

  test "read gives :error for a missing file and for another version", %{root: root} do
    assert Tia.Map.read(Path.join(root, "nope.json")) == :error

    path = Path.join(root, "old.json")
    File.write!(path, ~s({"version": 1, "tests": {}}))
    assert Tia.Map.read(path) == :error
  end

  test "prune drops entries of test files that left the disk", %{root: root, map: map} do
    File.rm!(Path.join(root, "test/a_test.exs"))
    pruned = Tia.Map.prune(map, Tia.Config.new(root: root))

    assert Map.keys(pruned["tests"]) == ["test/b_test.exs"]
  end

  test "global files are configurable", %{root: root} do
    write(root, "priv/repo/seeds.exs", "one")
    config = Tia.Config.new(root: root, extra_global_files: ["priv/repo/seeds.exs"])
    map = Tia.Map.new(config)
    write(root, "priv/repo/seeds.exs", "two")

    assert {:all, _reason} = Tia.Map.plan(map, config)
  end

  test "an unknown option raises" do
    assert_raise KeyError, fn -> Tia.Config.new(nope: 1) end
  end
end
