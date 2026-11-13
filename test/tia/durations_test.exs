defmodule Tia.DurationsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: dir}, do: %{path: Path.join(dir, ".tia/durations.bin")}

  test "the path is next to the hash cache, and there is none without a cache", %{tmp_dir: dir} do
    assert Tia.Durations.path(Tia.Config.new(root: dir)) == Path.join(dir, ".tia/durations.bin")

    assert Tia.Durations.path(Tia.Config.new(root: dir, cache: "local/hashes.bin")) ==
             Path.join(dir, "local/durations.bin")

    assert Tia.Durations.path(Tia.Config.new(root: dir, cache: "/elsewhere/cache.bin")) ==
             "/elsewhere/durations.bin"

    assert Tia.Durations.path(Tia.Config.new(root: dir, cache: false)) == nil
    assert Tia.Durations.path(Tia.Config.new(root: dir, cache: nil)) == nil
  end

  test "what is written is read back, and no temporary file is left", %{path: path} do
    durations = %{"test/a_test.exs" => 12, "test/b test.exs" => 0}

    assert Tia.Durations.write(path, durations) == :ok
    assert Tia.Durations.read(path) == durations
    assert File.ls!(Path.dirname(path)) == ["durations.bin"]

    assert Tia.Durations.write(path, %{"test/a_test.exs" => 15}) == :ok
    assert Tia.Durations.read(path) == %{"test/a_test.exs" => 15}
    assert File.ls!(Path.dirname(path)) == ["durations.bin"]
  end

  test "a missing file, a damaged one or one of another version counts as empty", %{path: path} do
    assert Tia.Durations.read(path) == %{}
    File.mkdir_p!(Path.dirname(path))

    for body <- [
          "",
          "not a term",
          <<131, 104, 3>>,
          :erlang.term_to_binary({:tia_durations, 0, %{"test/a_test.exs" => 1}}),
          :erlang.term_to_binary({:tia_durations, 1, [:not, :a, :map]}),
          :erlang.term_to_binary({:tia_cache, 1, %{}}),
          :erlang.term_to_binary(%{"test/a_test.exs" => 1})
        ] do
      File.write!(path, body)
      assert Tia.Durations.read(path) == %{}
    end
  end

  test "an entry of the wrong shape is skipped and the others are kept", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    entries = %{
      "test/a_test.exs" => 7,
      "test/b_test.exs" => -1,
      "test/c_test.exs" => 1.5,
      "test/d_test.exs" => "9",
      :odd => 3
    }

    File.write!(path, :erlang.term_to_binary({:tia_durations, 1, entries}))
    assert Tia.Durations.read(path) == %{"test/a_test.exs" => 7}
  end

  test "without a path nothing is read and nothing is written", %{tmp_dir: dir} do
    assert Tia.Durations.read(nil) == %{}
    assert Tia.Durations.write(nil, %{"test/a_test.exs" => 1}) == :ok
    assert File.ls!(dir) == []
  end

  test "durations that cannot be written are an error, not a crash", %{tmp_dir: dir} do
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "a file where a directory is needed")

    assert {:error, _reason} =
             Tia.Durations.write(Path.join(blocker, "durations.bin"), %{"test/a_test.exs" => 1})
  end
end
