defmodule Tia.Recorder do
  @moduledoc """
  Reads which modules and source files have run since the last `reset/1`.

  It uses the JIT's native function counters (`:code.set_coverage_mode/1`,
  OTP 27+). Unlike `:cover` they need no recompilation, and reading or zeroing
  them is cheap enough to do between every two test files. A module counts as
  executed when any of its functions was entered, which is the only thing the
  map needs to know.
  """

  @doc """
  Switches to function counters and reloads the application's modules under
  them. Must run before the application starts: a module loaded earlier has no
  counters.
  """
  @spec start(atom()) :: [module()]
  def start(app) do
    ensure_supported(:code.coverage_support())
    _previous = :code.set_coverage_mode(:function_counters)
    :ok = Application.ensure_loaded(app)
    modules = Application.spec(app, :modules)

    Enum.each(modules, fn module ->
      :code.purge(module)
      :code.delete(module)
    end)

    :ok = :code.ensure_modules_loaded(modules)
    modules
  end

  @doc """
  Drops the modules matched by the `:ignore_modules` option of `Tia.Config`:
  an atom matches that module, a string matches every module whose name
  starts with it.
  """
  @spec reject_ignored([module()], [module() | String.t()]) :: [module()]
  def reject_ignored(modules, []), do: modules

  def reject_ignored(modules, ignored) do
    Enum.reject(modules, fn module ->
      name = inspect(module)

      Enum.any?(ignored, fn
        pattern when is_atom(pattern) -> pattern == module
        prefix when is_binary(prefix) -> String.starts_with?(name, prefix)
      end)
    end)
  end

  @doc "Zeroes the counters of the given modules."
  @spec reset([module()]) :: :ok
  def reset(modules), do: Enum.each(modules, &:code.reset_coverage/1)

  @doc """
  Returns the sorted modules, out of the given ones, that executed since
  `reset/1`. Macros count: a case template whose `__using__/1` expanded while
  a test file was being compiled is executed.
  """
  @spec executed_modules([module()]) :: [module()]
  def executed_modules(modules), do: modules |> Enum.filter(&executed?/1) |> Enum.sort()

  @doc """
  Returns the sorted files behind the given modules: each module's source plus
  its `@external_resource` files, which is how templates and other compiled-in
  data end up in the map.
  """
  @spec sources([module()], Path.t()) :: [String.t()]
  def sources(modules, root) do
    root = Path.expand(root)

    modules
    |> Enum.flat_map(&files_of/1)
    |> Enum.map(&relative(&1, root))
    |> Enum.filter(&(Path.type(&1) == :relative))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ensure_supported(true), do: :ok

  defp ensure_supported(false) do
    raise "tia needs native coverage support: OTP 27+ running under the JIT"
  end

  defp executed?(module) do
    Enum.any?(:code.get_coverage(:function, module), fn {_function, calls} -> calls > 0 end)
  end

  defp files_of(module) do
    resources = module.module_info(:attributes) |> Keyword.get_values(:external_resource)
    List.flatten([source_of(module) | resources])
  end

  defp source_of(module) do
    case module.module_info(:compile)[:source] do
      nil -> []
      source -> [List.to_string(source)]
    end
  end

  defp relative(path, root) do
    path
    |> Path.relative_to(root)
    |> String.replace(~r{^_build/[^/]+/lib/[^/]+/priv/}, "priv/")
  end
end
