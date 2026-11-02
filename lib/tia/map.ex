defmodule Tia.Map do
  @moduledoc """
  The recorded dependency map and the rules that keep it honest.

  For each test file the map stores the source files it executed and one
  fingerprint: the content hash of the test file and of every one of those
  sources. A test file is stale when it has no entry or when its fingerprint
  no longer matches the files on disk, so the map validates itself and needs
  no help from `git`.

  A separate `globals` fingerprint covers what a per-test map cannot see:
  dependencies, configuration, migrations, `test_helper.exs` and any file that
  defines macros. When it changes, every test file is stale.
  """

  alias Tia.Config

  @version 3

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

  @doc "Stores the sources a test file executed, fingerprinted against the disk."
  @spec put(t(), Config.t(), String.t(), [String.t()]) :: t()
  def put(%{"tests" => tests} = map, %Config{} = config, test_file, sources) do
    hashes = hashes(config, [test_file | sources])
    entry = %{"hash" => fingerprint([test_file | sources], hashes), "sources" => sources}
    %{map | "tests" => Map.put(tests, test_file, entry)}
  end

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
      config.global_files ++
        config.extra_global_files ++ expand(config, config.global_globs) ++ macro_files(config)

    files |> Enum.uniq() |> then(&fingerprint(&1, hashes(config, &1)))
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
      _moved -> {:all, "dependencies, config, migrations or macros changed"}
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
    recorded = Enum.flat_map(tests, fn {_file, %{"sources" => sources}} -> sources end)
    hashes = hashes(config, Enum.uniq(disk ++ recorded))

    for file <- disk, stale_entry?(Map.get(tests, file), file, hashes), do: file
  end

  defp encode_entry(%{"hash" => hash, "sources" => sources}),
    do: "{\"hash\":#{JSON.encode!(hash)},\"sources\":#{JSON.encode!(sources)}}"

  defp stale_entry?(nil, _file, _hashes), do: true

  defp stale_entry?(%{"hash" => hash, "sources" => sources}, file, hashes),
    do: fingerprint([file | sources], hashes) != hash

  defp fingerprint(files, hashes) do
    files
    |> Enum.sort()
    |> Enum.map_join("\n", &"#{&1} #{Map.fetch!(hashes, &1)}")
    |> digest()
  end

  defp hashes(config, paths), do: Map.new(paths, &{&1, file_hash(config, &1)})

  defp file_hash(%Config{root: root}, path) do
    case File.read(Path.join(root, path)) do
      {:ok, body} -> digest(body)
      {:error, _} -> "missing"
    end
  end

  defp digest(body),
    do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp macro_files(%Config{root: root} = config) do
    for path <- expand(config, config.macro_globs),
        String.contains?(File.read!(Path.join(root, path)), config.macro_markers),
        do: path
  end

  defp expand(%Config{root: root}, globs) do
    for glob <- globs,
        path <- Path.wildcard(Path.join(root, glob)),
        do: Path.relative_to(path, root)
  end
end
