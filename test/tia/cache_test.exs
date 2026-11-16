defmodule Tia.CacheTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    file = Path.join(dir, "source.ex")
    File.write!(file, "one")
    age(file, 60)
    %{source: file, path: Path.join(dir, ".tia/cache.bin")}
  end

  # Sets the modification time of the file to `seconds` ago.
  defp age(file, seconds), do: File.touch!(file, System.os_time(:second) - seconds)

  # Fetches through the cache and tells whether the hash had to be computed.
  defp fetch(cache, file, hash, kind \\ :file) do
    result =
      Tia.Cache.fetch(cache, kind, file, fn ->
        send(self(), :computed)
        hash
      end)

    receive do
      :computed -> {:computed, result}
    after
      0 -> {:cached, result}
    end
  end

  test "a hit gives the stored hash back, in the same run and after a flush", %{
    source: file,
    path: path
  } do
    cache = Tia.Cache.open(path)
    assert fetch(cache, file, "h1") == {:computed, "h1"}
    assert fetch(cache, file, "other") == {:cached, "h1"}
    assert Tia.Cache.flush(cache) == :ok

    reopened = Tia.Cache.open(path)
    assert fetch(reopened, file, "other") == {:cached, "h1"}
  end

  test "a new modification time is a miss, and so is a new size", %{source: file, path: path} do
    cache = Tia.Cache.open(path)
    assert fetch(cache, file, "h1") == {:computed, "h1"}
    Tia.Cache.flush(cache)

    age(file, 30)
    cache = Tia.Cache.open(path)
    assert fetch(cache, file, "h2") == {:computed, "h2"}
    assert fetch(cache, file, "other") == {:cached, "h2"}
    Tia.Cache.flush(cache)

    File.write!(file, "three")
    age(file, 30)
    cache = Tia.Cache.open(path)
    assert fetch(cache, file, "h3") == {:computed, "h3"}
    assert fetch(cache, file, "other") == {:cached, "h3"}
  end

  test "the kind of hash is part of the key", %{source: file, path: path} do
    cache = Tia.Cache.open(path)
    assert fetch(cache, file, "content") == {:computed, "content"}
    assert fetch(cache, file, "digest a", {:beam, "/a"}) == {:computed, "digest a"}
    assert fetch(cache, file, "digest b", {:beam, "/b"}) == {:computed, "digest b"}
    assert fetch(cache, file, "other", {:beam, "/a"}) == {:cached, "digest a"}
    assert fetch(cache, file, "other") == {:cached, "content"}
  end

  test "a damaged cache, or one of another version, counts as empty", %{source: file, path: path} do
    File.mkdir_p!(Path.dirname(path))

    for body <- [
          "not a term",
          <<131, 104, 3>>,
          :erlang.term_to_binary({:tia_cache, 0, %{{:file, file} => {{1, 3}, "old"}}}),
          :erlang.term_to_binary({:tia_cache, 1, [:not, :a, :map]}),
          :erlang.term_to_binary(%{})
        ] do
      File.write!(path, body)
      cache = Tia.Cache.open(path)
      assert fetch(cache, file, "fresh") == {:computed, "fresh"}
      assert Tia.Cache.flush(cache) == :ok
      assert fetch(Tia.Cache.open(path), file, "other") == {:cached, "fresh"}
    end
  end

  test "an entry of the wrong shape is skipped and the others are kept", %{
    source: file,
    path: path
  } do
    cache = Tia.Cache.open(path)
    fetch(cache, file, "h1")
    Tia.Cache.flush(cache)

    {:tia_cache, version, entries} = path |> File.read!() |> :erlang.binary_to_term()
    File.write!(path, :erlang.term_to_binary({:tia_cache, version, Map.put(entries, :odd, 1)}))

    assert fetch(Tia.Cache.open(path), file, "other") == {:cached, "h1"}
  end

  test "a file modified in the last two seconds is hashed every time", %{source: file, path: path} do
    File.write!(file, "now")
    cache = Tia.Cache.open(path)
    assert fetch(cache, file, "h1") == {:computed, "h1"}
    assert fetch(cache, file, "h2") == {:computed, "h2"}
    assert Tia.Cache.flush(cache) == :ok
    refute File.exists?(path)
  end

  test "a missing file is computed and never cached", %{tmp_dir: dir, path: path} do
    cache = Tia.Cache.open(path)
    missing = Path.join(dir, "nope.ex")
    assert fetch(cache, missing, "missing") == {:computed, "missing"}
    assert fetch(cache, missing, "missing") == {:computed, "missing"}
    assert fetch(cache, dir, "a directory") == {:computed, "a directory"}
    assert Tia.Cache.flush(cache) == :ok
    refute File.exists?(path)
  end

  test "flush writes only when there is something new, and leaves no temporary file", %{
    source: file,
    path: path
  } do
    cache = Tia.Cache.open(path)
    fetch(cache, file, "h1")
    assert Tia.Cache.flush(cache) == :ok
    assert File.ls!(Path.dirname(path)) == ["cache.bin"]

    # Something to tell a second write by.
    age(path, 100)
    written = File.stat!(path, time: :posix).mtime

    assert Tia.Cache.flush(cache) == :ok
    reopened = Tia.Cache.open(path)
    assert fetch(reopened, file, "other") == {:cached, "h1"}
    assert Tia.Cache.flush(reopened) == :ok
    assert File.stat!(path, time: :posix).mtime == written
  end

  test "flush drops the entries of files that left the disk", %{
    tmp_dir: dir,
    source: file,
    path: path
  } do
    gone = Path.join(dir, "gone.ex")
    File.write!(gone, "x")
    age(gone, 60)

    cache = Tia.Cache.open(path)
    fetch(cache, file, "h1")
    fetch(cache, gone, "h2")
    File.rm!(gone)
    Tia.Cache.flush(cache)

    {:tia_cache, _version, entries} = path |> File.read!() |> :erlang.binary_to_term()
    assert Map.keys(entries) == [{:file, file}]
  end

  test "a cache that cannot be written is an error, not a crash", %{tmp_dir: dir, source: file} do
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "a file where a directory is needed")
    cache = Tia.Cache.open(Path.join(blocker, "cache.bin"))

    assert fetch(cache, file, "h1") == {:computed, "h1"}
    assert {:error, _reason} = Tia.Cache.flush(cache)
  end

  test "without an open cache, fetch computes and flush does nothing", %{source: file} do
    for closed <- [nil, false, ".tia/cache.bin"] do
      assert fetch(closed, file, "h1") == {:computed, "h1"}
      assert fetch(closed, file, "h2") == {:computed, "h2"}
      assert Tia.Cache.flush(closed) == :ok
    end

    assert Tia.Cache.open(false) == nil
    assert Tia.Cache.open(nil) == nil
  end

  test "attach opens the cache of the config under its root", %{tmp_dir: dir, source: file} do
    config = Tia.Cache.attach(Tia.Config.new(root: dir))
    assert fetch(config.cache, file, "h1") == {:computed, "h1"}
    assert Tia.Cache.flush(config.cache) == :ok
    assert File.exists?(Path.join(dir, ".tia/cache.bin"))

    assert Tia.Cache.attach(Tia.Config.new(root: dir, cache: false)).cache == false
    assert Tia.Cache.attach(config) == config
  end
end
