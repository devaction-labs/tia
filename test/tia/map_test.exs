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
    beam(root, "Elixir.A", 1)
    beam(root, "Elixir.B", 1)
    config = Tia.Config.new(root: root, ebin: "ebin")

    map =
      config
      |> Tia.Map.new()
      |> Tia.Map.put(config, "test/a_test.exs", ["lib/a.ex"], ["Elixir.A"])
      |> Tia.Map.put(config, "test/b_test.exs", ["lib/b.ex"], ["Elixir.B"])

    %{root: root, map: map, config: config}
  end

  # Compiles a module that returns `value` straight to `ebin/`, without loading it.
  defp beam(root, name, value) do
    module = String.to_atom(name)

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [value: 0]},
      {:function, 1, :value, 0, [{:clause, 1, [], [], [{:integer, 1, value}]}]}
    ]

    {:ok, ^module, binary} = :compile.forms(forms)
    write(root, "ebin/#{name}.beam", binary)
  end

  defp write(root, path, body) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
  end

  test "a freshly recorded map has nothing stale", %{root: root, map: map} do
    assert Tia.Map.plan(map, Tia.Config.new(root: root, ebin: "ebin")) == {:run, []}
  end

  test "changing a recorded source makes only its tests stale", %{root: root, map: map} do
    write(root, "lib/a.ex", "defmodule A, do: 1")

    assert Tia.Map.plan(map, Tia.Config.new(root: root, ebin: "ebin")) ==
             {:run, ["test/a_test.exs"]}
  end

  test "changing the test file itself makes it stale", %{root: root, map: map} do
    write(root, "test/b_test.exs", "changed")

    assert Tia.Map.plan(map, Tia.Config.new(root: root, ebin: "ebin")) ==
             {:run, ["test/b_test.exs"]}
  end

  test "a deleted source makes its tests stale", %{root: root, map: map} do
    File.rm!(Path.join(root, "lib/b.ex"))

    assert Tia.Map.plan(map, Tia.Config.new(root: root, ebin: "ebin")) ==
             {:run, ["test/b_test.exs"]}
  end

  test "a test file with no entry is stale, so a renamed file cannot slip through", %{
    root: root,
    map: map
  } do
    File.rename!(Path.join(root, "test/a_test.exs"), Path.join(root, "test/renamed_test.exs"))

    assert Tia.Map.plan(map, Tia.Config.new(root: root, ebin: "ebin")) ==
             {:run, ["test/renamed_test.exs"]}
  end

  test "moving the globals makes everything stale", %{root: root, map: map} do
    write(root, "mix.lock", "new lock")

    assert {:all, _reason} = Tia.Map.plan(map, Tia.Config.new(root: root, ebin: "ebin"))
  end

  test "changing an env config that is not global does not move the globals", %{
    root: root,
    map: map
  } do
    write(root, "config/dev.exs", "dev")
    write(root, "config/prod.exs", "prod")

    assert Tia.Map.plan(map, Tia.Config.new(root: root, ebin: "ebin")) == {:run, []}
  end

  test "changing config/test.exs moves the globals", %{root: root} do
    write(root, "config/test.exs", "t")
    config = Tia.Config.new(root: root, ebin: "ebin")
    map = Tia.Map.new(config)
    write(root, "config/test.exs", "t2")

    assert {:all, _reason} = Tia.Map.plan(map, config)
  end

  test "changing the beam of a recorded module makes only the tests that ran it stale", %{
    root: root,
    map: map,
    config: config
  } do
    beam(root, "Elixir.A", 2)

    assert Tia.Map.plan(map, config) == {:run, ["test/a_test.exs"]}
  end

  test "recompiling a recorded module to the same code leaves nothing stale", %{
    root: root,
    map: map,
    config: config
  } do
    beam(root, "Elixir.A", 1)

    assert Tia.Map.plan(map, config) == {:run, []}
  end

  test "a recorded module whose beam is gone makes its tests stale", %{
    root: root,
    map: map,
    config: config
  } do
    File.rm!(Path.join(root, "ebin/Elixir.B.beam"))

    assert Tia.Map.plan(map, config) == {:run, ["test/b_test.exs"]}
  end

  test "the ebin directory may be absolute", %{root: root, map: map} do
    config = Tia.Config.new(root: root, ebin: Path.expand("ebin", root))
    assert Tia.Map.plan(map, config) == {:run, []}

    beam(root, "Elixir.B", 2)
    assert Tia.Map.plan(map, config) == {:run, ["test/b_test.exs"]}
  end

  test "a file that defines macros no longer moves the globals", %{root: root, map: map} do
    write(root, "lib/macros.ex", "defmacro x, do: nil")
    write(root, "test/support/data_case.ex", "using do")
    config = Tia.Config.new(root: root, ebin: "ebin")
    globals = Tia.Map.globals(config)
    write(root, "lib/macros.ex", "defmacro y, do: nil")
    write(root, "test/support/data_case.ex", "using(opts)")

    assert Tia.Map.globals(config) == globals
    assert Tia.Map.plan(map, config) == {:run, []}
  end

  test "select adds the tests whose sources are in the diff to the stale ones", %{
    root: root,
    map: map
  } do
    write(root, "test/b_test.exs", "changed")

    assert Tia.Map.select(map, ["lib/a.ex"], Tia.Config.new(root: root, ebin: "ebin")) ==
             {:run, ["test/a_test.exs", "test/b_test.exs"]}
  end

  test "select runs nothing when the diff touches no recorded source", %{root: root, map: map} do
    assert Tia.Map.select(map, ["README.md"], Tia.Config.new(root: root, ebin: "ebin")) ==
             {:run, []}
  end

  test "delete leaves the test file stale", %{root: root, map: map} do
    map = Tia.Map.delete(map, "test/a_test.exs")

    assert Tia.Map.plan(map, Tia.Config.new(root: root, ebin: "ebin")) ==
             {:run, ["test/a_test.exs"]}
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

  test "the duration is stored on the same line and is not part of the fingerprint", %{
    root: root,
    map: map,
    config: config
  } do
    timed = Tia.Map.put(map, config, "test/a_test.exs", ["lib/a.ex"], ["Elixir.A"], 1234)

    assert timed["tests"]["test/a_test.exs"]["ms"] == 1234
    assert timed["tests"]["test/a_test.exs"]["hash"] == map["tests"]["test/a_test.exs"]["hash"]
    refute Map.has_key?(map["tests"]["test/a_test.exs"], "ms")
    assert Tia.Map.durations(timed) == %{"test/a_test.exs" => 1234}
    assert Tia.Map.durations(map) == %{}
    assert Tia.Map.plan(timed, config) == {:run, []}

    path = Path.join(root, ".tia/map.json")
    assert :ok = Tia.Map.write(timed, path)
    assert {:ok, ^timed} = Tia.Map.read(path)

    lines = path |> File.read!() |> String.split("\n")
    assert Enum.count(lines, &String.contains?(&1, "_test.exs")) == 2
    assert [line] = Enum.filter(lines, &String.contains?(&1, ~s("ms":1234,)))
    assert line =~ "test/a_test.exs"
  end

  test "with a cache the plan is the same and follows the disk", %{root: root, map: map} do
    for path <-
          Path.wildcard(Path.join(root, "{lib,test,ebin}/*")) ++ [Path.join(root, "mix.exs")],
        do: File.touch!(path, System.os_time(:second) - 60)

    config = Tia.Cache.attach(Tia.Config.new(root: root, ebin: "ebin"))
    assert Tia.Map.plan(map, config) == {:run, []}
    assert Tia.Cache.flush(config.cache) == :ok

    {:tia_cache, _version, entries} =
      root |> Path.join(".tia/cache.bin") |> File.read!() |> :erlang.binary_to_term()

    assert is_map_key(entries, {:file, Path.join(root, "lib/a.ex")})
    assert is_map_key(entries, {:file, Path.join(root, "mix.exs")})
    assert is_map_key(entries, {{:beam, root}, Path.join(root, "ebin/Elixir.A.beam")})

    # A cached hash is used as it is: this is what a hit looks like.
    key = {:file, Path.join(root, "lib/a.ex")}
    {stamp, _hash} = Map.fetch!(entries, key)
    poisoned = Map.put(entries, key, {stamp, "not the hash"})

    File.write!(
      Path.join(root, ".tia/cache.bin"),
      :erlang.term_to_binary({:tia_cache, 1, poisoned})
    )

    config = Tia.Cache.attach(Tia.Config.new(root: root, ebin: "ebin"))
    assert Tia.Map.plan(map, config) == {:run, ["test/a_test.exs"]}

    # A file written again has another modification time, so it is hashed again.
    write(root, "lib/a.ex", "defmodule A, do: nil")
    write(root, "lib/b.ex", "defmodule B, do: :changed")
    config = Tia.Cache.attach(Tia.Config.new(root: root, ebin: "ebin"))
    assert Tia.Map.plan(map, config) == {:run, ["test/b_test.exs"]}
  end

  test "read gives :error for a missing file and for another version", %{root: root} do
    assert Tia.Map.read(Path.join(root, "nope.json")) == :error

    path = Path.join(root, "old.json")
    File.write!(path, ~s({"version": 3, "globals": "g", "tests": {}}))
    assert Tia.Map.read(path) == :error
  end

  test "prune drops entries of test files that left the disk", %{root: root, map: map} do
    File.rm!(Path.join(root, "test/a_test.exs"))
    pruned = Tia.Map.prune(map, Tia.Config.new(root: root, ebin: "ebin"))

    assert Map.keys(pruned["tests"]) == ["test/b_test.exs"]
  end

  test "global files are configurable", %{root: root} do
    write(root, "priv/repo/seeds.exs", "one")
    config = Tia.Config.new(root: root, extra_global_files: ["priv/repo/seeds.exs"])
    map = Tia.Map.new(config)
    write(root, "priv/repo/seeds.exs", "two")

    assert {:all, _reason} = Tia.Map.plan(map, config)
  end

  test "an unknown option raises, and so do the removed macro options" do
    assert_raise KeyError, fn -> Tia.Config.new(nope: 1) end
    assert_raise KeyError, fn -> Tia.Config.new(macro_globs: ["lib/**/*.ex"]) end
    assert_raise KeyError, fn -> Tia.Config.new(macro_markers: ["defmacro"]) end
  end
end
