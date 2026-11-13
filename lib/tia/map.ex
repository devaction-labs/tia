defmodule Tia.Map do
  @moduledoc """
  The recorded dependency map and the rules that keep it honest.

  For each test file the map stores the source files and the modules it
  executed, and one fingerprint: the content hash of the test file and of
  every one of those sources, plus the `Tia.Beam.digest/2` of the compiled
  `.beam` file of every one of those modules. A test file is stale when it has
  no entry or when its fingerprint no longer matches the disk, so the map
  validates itself and needs no help from `git`.

  The BEAM digest is what catches compile-time dependencies: when a macro or a
  value inlined at compile time changes, Mix recompiles the modules that used
  it, their expanded code changes, and only the test files that executed those
  modules go stale. The digest is read from the file in `Tia.Config`'s `:ebin`
  directory, never from the loaded module, because recording replaces the
  loaded code with an instrumented copy.

  An entry may also carry `ms`, the wall-clock time recording the test file
  took. It is not part of the fingerprint: `mix tia --partitions` reads it to
  hand out the slowest test files first.

  Hashing goes through `Tia.Cache` when the config carries an open cache, see
  `Tia.Cache.attach/1`.

  A separate `globals` fingerprint covers what a per-test map cannot see:
  dependencies, configuration, migrations and `test_helper.exs`. When it
  changes, every test file is stale.
  """

  alias Tia.Config

  @version 4

  @type t :: %{required(String.t()) => term()}
  @type selection :: {:run, [String.t()]} | {:all, String.t()}

  @doc "An empty map stamped with the current globals."
  @spec new(Config.t()) :: t()
  def new(%Config{} = config),
    do: %{"version" => @version, "globals" => globals(config), "tests" => %{}}

  @doc "Reads a map, or `:error` when it is missing, unreadable or of another version."
  @spec read(Path.t()) :: {:ok, t()} | :error
  def read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"version" => @version} = map} <- JSON.decode(body) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  @doc "Writes the map with one test file per line, so concurrent edits merge cleanly."
  @spec write(t(), Path.t()) :: :ok
  def write(%{"tests" => tests} = map, path) do
    File.mkdir_p!(Path.dirname(path))

    lines =
      for {file, entry} <- Enum.sort(tests),
          do: "    #{JSON.encode!(file)}: #{encode_entry(entry)}"

    File.write!(path, [
      "{\n  \"version\": #{@version},\n  \"globals\": #{JSON.encode!(map["globals"])},\n",
      "  \"tests\": {\n",
      Enum.join(lines, ",\n"),
      "\n  }\n}\n"
    ])
  end

  @doc """
  Stores the sources and the modules a test file executed, fingerprinted
  against the disk. Modules are given by name, as in `"Elixir.MyApp.User"`.
  `ms` is the time the recording took, in milliseconds; without it the entry
  has no duration.
  """
  @spec put(t(), Config.t(), String.t(), [String.t()], [String.t()], non_neg_integer() | nil) ::
          t()
  def put(%{"tests" => tests} = map, %Config{} = config, test_file, sources, modules, ms \\ nil) do
    files = [test_file | sources]
    hash = fingerprint(files, hashes(config, files), modules, beams(config, modules))
    entry = %{"hash" => hash, "modules" => modules, "sources" => sources}
    entry = if is_integer(ms), do: Map.put(entry, "ms", ms), else: entry
    %{map | "tests" => Map.put(tests, test_file, entry)}
  end

  @doc "The recorded duration of each test file that has one, in milliseconds."
  @spec durations(t()) :: %{String.t() => non_neg_integer()}
  def durations(%{"tests" => tests}),
    do: for({file, %{"ms" => ms}} <- tests, is_integer(ms), into: %{}, do: {file, ms})

  @doc "Forgets a test file, which makes it stale until it is recorded again."
  @spec delete(t(), String.t()) :: t()
  def delete(%{"tests" => tests} = map, test_file),
    do: %{map | "tests" => Map.delete(tests, test_file)}

  @doc "Drops the entries of test files that no longer exist on disk."
  @spec prune(t(), Config.t()) :: t()
  def prune(%{"tests" => tests} = map, %Config{} = config),
    do: %{map | "tests" => Map.take(tests, test_files(config))}

  @doc "The fingerprint of everything the per-test map cannot see."
  @spec globals(Config.t()) :: String.t()
  def globals(%Config{} = config) do
    files =
      config.global_files ++ config.extra_global_files ++ expand(config, config.global_globs)

    files |> Enum.uniq() |> then(&fingerprint(&1, hashes(config, &1), [], %{}))
  end

  @doc "Every test file on disk."
  @spec test_files(Config.t()) :: [String.t()]
  def test_files(%Config{} = config), do: Enum.sort(expand(config, config.test_globs))

  @doc """
  What a local run has to execute: `{:all, reason}` when the globals moved,
  otherwise `{:run, stale_test_files}`.
  """
  @spec plan(t(), Config.t()) :: selection()
  def plan(%{"globals" => recorded} = map, %Config{} = config) do
    case globals(config) do
      ^recorded -> {:run, stale(map, config)}
      _moved -> {:all, "dependencies, config or migrations changed"}
    end
  end

  @doc """
  What CI has to execute for a diff: the stale test files plus every test file
  whose recorded sources include a changed path.
  """
  @spec select(t(), [String.t()], Config.t()) :: selection()
  def select(map, changed, %Config{} = config) do
    case plan(map, config) do
      {:all, _reason} = all -> all
      {:run, stale} -> {:run, Enum.sort(Enum.uniq(stale ++ affected(map, changed)))}
    end
  end

  @doc "Test files whose recorded sources include any of the changed paths."
  @spec affected(t(), [String.t()]) :: [String.t()]
  def affected(%{"tests" => tests}, changed) do
    changed = MapSet.new(changed)

    for {file, %{"sources" => sources}} <- tests,
        Enum.any?(sources, &MapSet.member?(changed, &1)),
        do: file
  end

  @doc "Test files on disk that have no entry or whose fingerprint no longer matches."
  @spec stale(t(), Config.t()) :: [String.t()]
  def stale(%{"tests" => tests}, %Config{} = config) do
    disk = test_files(config)
    entries = Map.values(tests)
    hashes = hashes(config, Enum.uniq(disk ++ Enum.flat_map(entries, & &1["sources"])))
    beams = beams(config, Enum.uniq(Enum.flat_map(entries, & &1["modules"])))

    for file <- disk, stale_entry?(Map.get(tests, file), file, hashes, beams), do: file
  end

  defp encode_entry(%{"hash" => hash, "modules" => modules, "sources" => sources} = entry) do
    "{\"hash\":#{JSON.encode!(hash)},\"modules\":#{JSON.encode!(modules)}," <>
      encode_ms(entry) <> "\"sources\":#{JSON.encode!(sources)}}"
  end

  defp encode_ms(%{"ms" => ms}) when is_integer(ms), do: "\"ms\":#{ms},"
  defp encode_ms(_entry), do: ""

  defp stale_entry?(nil, _file, _hashes, _beams), do: true

  defp stale_entry?(%{"hash" => hash, "modules" => modules, "sources" => sources}, file, h, b),
    do: fingerprint([file | sources], h, modules, b) != hash

  defp fingerprint(files, hashes, modules, beams) do
    file_lines = for file <- Enum.sort(files), do: "#{file} #{Map.fetch!(hashes, file)}"

    beam_lines =
      for module <- Enum.sort(modules), do: "beam #{module} #{Map.fetch!(beams, module)}"

    digest(Enum.join(file_lines ++ beam_lines, "\n"))
  end

  defp hashes(%Config{root: root} = config, paths) do
    root = Path.expand(root)
    Map.new(paths, &{&1, file_hash(config, Path.join(root, &1))})
  end

  defp file_hash(%Config{cache: cache}, path) do
    Tia.Cache.fetch(cache, :file, path, fn ->
      case File.read(path) do
        {:ok, body} -> digest(body)
        {:error, _} -> "missing"
      end
    end)
  end

  defp beams(%Config{ebin: nil}, modules), do: Map.new(modules, &{&1, "missing"})

  defp beams(%Config{root: root, ebin: ebin, cache: cache}, modules) do
    root = Path.expand(root)
    ebin = Path.expand(ebin, root)

    modules
    |> Task.async_stream(&{&1, beam_hash(cache, root, Path.join(ebin, &1 <> ".beam"))},
      ordered: false,
      timeout: :infinity
    )
    |> Map.new(fn {:ok, pair} -> pair end)
  end

  # The digest depends on the root only through the paths it takes out, but
  # the cache cannot know that, so the root is part of the key.
  defp beam_hash(cache, root, path) do
    Tia.Cache.fetch(cache, {:beam, root}, path, fn ->
      case Tia.Beam.digest(path, root) do
        {:ok, digest} -> digest
        :error -> "missing"
      end
    end)
  end

  defp digest(body),
    do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp expand(%Config{root: root}, globs) do
    for glob <- globs,
        path <- Path.wildcard(Path.join(root, glob)),
        do: Path.relative_to(path, root)
  end
end
