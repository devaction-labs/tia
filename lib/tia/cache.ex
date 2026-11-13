defmodule Tia.Cache do
  @moduledoc """
  A local cache of the hashes `Tia.Map` takes of sources and `.beam` files.

  Selecting the stale test files hashes every test file, every recorded
  source and every recorded module, on every run. The cache keeps each hash
  under the absolute path of its file, with the modification time and the size
  the file had, and gives it back for as long as both are the same.

  It lives in the file named by the `:cache` option of `Tia.Config`, by
  default `.tia/cache.bin`, and belongs to one checkout: keep it out of
  version control. Losing it only costs the time to hash everything again. A
  file that is missing, damaged or written by another version of Tia counts
  as an empty cache.

  Two things follow from trusting the modification time:

    * a file modified less than two seconds ago is hashed and not cached,
      because the time has a resolution of one second and another write in
      the same second, of the same size, would go unseen;
    * a file whose content changes while its size and its modification time
      stay the same, as after `cp -p` or `touch -r`, keeps its old hash. Set
      `cache: false` or delete the file when a tool does that.

  A cache is opened with `open/1`, or with `attach/1` for the one of a
  `Tia.Config`, used through `fetch/4` from any process, and written back
  with `flush/1` when it holds something new. `fetch/4` on anything but an
  open cache just computes, so the cache is always optional.
  """

  # Bump when the content of a hash changes for the same file, as with a new
  # rule in `Tia.Beam`: the file on disk is then ignored.
  @version 1
  @settle 2

  @enforce_keys [:path, :table]
  defstruct [:path, :table]

  @opaque t :: %__MODULE__{path: Path.t(), table: :ets.table()}

  @typedoc "What was hashed: a file's content, or a module for a project root."
  @type kind :: :file | {:beam, Path.t() | nil}

  @doc """
  Opens the cache stored at `path`, or `nil` when `path` is `false` or `nil`.
  The table behind it belongs to the calling process.
  """
  @spec open(Path.t() | false | nil) :: t() | nil
  def open(path) when path in [false, nil], do: nil

  def open(path) when is_binary(path) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    :ets.insert(table, for({key, {stamp, hash}} <- load(path), do: {key, stamp, hash}))
    %__MODULE__{path: path, table: table}
  end

  @doc """
  Opens the cache the `:cache` option of the config names and puts it in the
  config, in place of the path. `Tia.Map` then hashes through it.
  """
  @spec attach(Tia.Config.t()) :: Tia.Config.t()
  def attach(%Tia.Config{cache: path, root: root} = config) when is_binary(path),
    do: %{config | cache: open(Path.expand(path, root))}

  def attach(%Tia.Config{} = config), do: config

  @doc """
  The hash of the file at the absolute `path`: the cached one when the file
  has the modification time and the size it had, otherwise the result of
  `compute`, which is then cached. A file that cannot be read is never cached.
  """
  @spec fetch(t() | term(), kind(), Path.t(), (-> String.t())) :: String.t()
  def fetch(%__MODULE__{table: table}, kind, path, compute) do
    key = {kind, path}

    case stamp(path) do
      nil ->
        compute.()

      stamp ->
        case :ets.lookup(table, key) do
          [{^key, ^stamp, hash}] -> hash
          _miss -> store(table, key, stamp, compute.())
        end
    end
  end

  def fetch(_not_open, _kind, _path, compute), do: compute.()

  @doc """
  Writes the cache back when it holds a hash the file does not, through a
  temporary file and a rename. Entries of files that left the disk are
  dropped on the way.
  """
  @spec flush(t() | term()) :: :ok | {:error, File.posix()}
  def flush(%__MODULE__{path: path, table: table}) do
    case :ets.take(table, :dirty) do
      [] -> :ok
      [_dirty] -> write(path, entries(table))
    end
  end

  def flush(_not_open), do: :ok

  defp store(table, key, {mtime, _size} = stamp, hash) do
    if System.os_time(:second) - mtime >= @settle do
      :ets.insert(table, [{key, stamp, hash}, {:dirty}])
    end

    hash
  end

  defp stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} -> {mtime, size}
      _missing_or_not_a_file -> nil
    end
  end

  defp entries(table) do
    for {{_kind, path} = key, stamp, hash} <- :ets.tab2list(table),
        File.exists?(path),
        into: %{},
        do: {key, {stamp, hash}}
  end

  defp load(path) do
    with {:ok, binary} <- File.read(path),
         {:tia_cache, @version, entries} when is_map(entries) <- decode(binary) do
      entries
    else
      _missing_damaged_or_other_version -> %{}
    end
  end

  defp decode(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> :error
  end

  defp write(path, entries) do
    temporary = "#{path}.#{System.pid()}.tmp"
    binary = :erlang.term_to_binary({:tia_cache, @version, entries})

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, binary),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}
    end
  end
end
