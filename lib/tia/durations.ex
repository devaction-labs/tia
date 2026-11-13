defmodule Tia.Durations do
  @moduledoc """
  How long the recording of each test file took, kept out of the map.

  `mix tia --partitions` hands out the slowest test files first, and for that
  it has to remember how long each one took. A duration changes on every run,
  so it does not belong in the map, which is committed and has to change only
  when a selection does. The durations live in `durations.bin`, in the
  directory of the hash cache, by default `.tia/durations.bin`, and belong to
  one checkout: keep the file out of version control.

  It is a file of its own and not a part of the cache because the two are
  thrown away for different reasons. The cache is dropped whenever its hashes
  cannot be trusted: a new rule in `Tia.Beam`, a tool that keeps modification
  times, a file that left the disk. None of that says anything about how long
  a test file takes.

  Losing the file only costs the order of the queue of one run: a test file
  with no duration is handed out before the others, in the order of the
  names. A file that is missing, damaged or written by another version of Tia
  counts as empty. With `cache: false` there is no file: `path/1` gives `nil`,
  `read/1` nothing and `write/2` does nothing.
  """

  @version 1
  @file_name "durations.bin"

  @type t :: %{String.t() => non_neg_integer()}

  @doc """
  Where the durations of a config live: next to its hash cache, or `nil` when
  the `:cache` option is `false`. Takes the config before `Tia.Cache.attach/1`.
  """
  @spec path(Tia.Config.t()) :: Path.t() | nil
  def path(%Tia.Config{cache: cache, root: root}) when is_binary(cache),
    do: cache |> Path.expand(root) |> Path.dirname() |> Path.join(@file_name)

  def path(%Tia.Config{}), do: nil

  @doc "The duration of each test file, in milliseconds, by its path in the map."
  @spec read(Path.t() | nil) :: t()
  def read(nil), do: %{}

  def read(path) when is_binary(path) do
    with {:ok, binary} <- File.read(path),
         {:tia_durations, @version, durations} when is_map(durations) <- decode(binary) do
      for {file, ms} <- durations, is_binary(file), is_integer(ms), ms >= 0, into: %{} do
        {file, ms}
      end
    else
      _missing_damaged_or_other_version -> %{}
    end
  end

  @doc "Writes the durations through a temporary file and a rename."
  @spec write(Path.t() | nil, t()) :: :ok | {:error, File.posix()}
  def write(nil, _durations), do: :ok

  def write(path, durations) when is_binary(path) and is_map(durations) do
    temporary = "#{path}.#{System.pid()}.tmp"
    binary = :erlang.term_to_binary({:tia_durations, @version, durations})

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

  defp decode(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> :error
  end
end
