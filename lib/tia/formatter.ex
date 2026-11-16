defmodule Tia.Formatter do
  @moduledoc """
  The ExUnit formatter `mix tia` records with: it prints the failures, in
  full and without colors, and nothing else.

  Recording runs ExUnit once per test file, so the default formatter would
  print its seed, its timing and its result line for every one of them.
  `mix tia` prints one progress line per test file instead and replaces the
  formatters configured in `test_helper.exs` with this one. `mix tia --check`
  runs `mix test` and keeps the configured formatters.
  """

  use GenServer

  import ExUnit.Formatter, only: [format_test_failure: 5, format_test_all_failure: 5]

  @impl true
  def init(_opts), do: {:ok, %{failures: 0, width: width()}}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, failures}} = test}, state) do
    count = state.failures + 1
    IO.puts(["\n", format_test_failure(test, failures, count, state.width, &plain/2)])
    logs(test.logs)
    {:noreply, %{state | failures: count}}
  end

  def handle_cast(
        {:module_finished, %ExUnit.TestModule{state: {:failed, failures}} = module},
        state
      ) do
    count = state.failures + 1
    IO.puts(["\n", format_test_all_failure(module, failures, count, state.width, &plain/2)])
    {:noreply, %{state | failures: count}}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp plain(:diff_enabled?, _default), do: false
  defp plain(:blame_diff, message), do: "-" <> message <> "-"
  defp plain(_key, message), do: message

  defp logs(""), do: :ok

  defp logs(output) do
    indent = "\n     "

    IO.puts([
      "     The following output was logged:",
      indent,
      String.replace(output, "\n", indent)
    ])
  end

  defp width do
    case :io.columns() do
      {:ok, width} -> max(40, width)
      _ -> 80
    end
  end
end
