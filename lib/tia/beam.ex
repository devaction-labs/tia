defmodule Tia.Beam do
  @moduledoc """
  A digest of a compiled module that survives an identical recompilation.

  `:beam_lib.md5/1` does not: two compilations of the same sources can give
  different `.beam` files. Since OTP 26 a small map iterates its atom keys in
  the order the atoms were created in the VM, and the parallel compiler creates
  them in a different order on every run. A macro that builds code by walking
  a map therefore emits the same pieces in another order, and the compiler
  numbers variables, anonymous functions and literals after it. The slots of a
  HEEx component, the fields of `@derive Jason.Encoder` and the commands of a
  Commanded router all do this.

  The digest is taken from the Elixir `debug_info` chunk instead, which holds
  every definition of the module after macro expansion, reduced to a canonical
  form:

    * the definitions, and the clauses of each definition, are sorted;
    * positional and hygiene metadata is dropped (`:line`, `:column`,
      `:version`, `:counter`, `:keep` and the like), other metadata stays;
    * the keys of a map and the elements of a list literal are sorted, and a
      string that sits directly in a list literal counts as a bag of words and
      punctuation, since a walk over a map reorders exactly these;
    * the integer `:fingerprint` of a map is dropped: Phoenix LiveView stores
      there a hash of the template, metadata included, next to the template
      itself;
    * the arguments of a call, the expressions of a block, the clauses of
      `fn`, `case` and friends, the elements of a tuple and the segments of a
      binary keep their order;
    * the specs and the file paths of the chunk are left out;
    * the definitions of `__mix_recompile__?/0` and `__phoenix_recompile__?/0`
      are left out: they are hooks that tell Mix, or the old `:phoenix`
      compiler, when to recompile the module, not code a test observes.

  So the digest still moves when a macro expands to different code or when a
  value inlined at compile time changes. What it cannot see is a change that
  only reorders the clauses of a function, the keys of a map, the elements of a
  list literal or the words of the strings in one, and touches nothing else.

  The canonical form is a heuristic: it covers the reorderings found in real
  projects, and a macro that derives code from the iteration order in another
  way can still give two digests for the same sources.

  Code that embeds `__ENV__.file`, as the Phoenix macros do, carries the
  absolute path of the checkout in its literals. `digest/2` takes the root of
  the project and, before anything else, swaps that path for a fixed
  placeholder wherever a string or a charlist of the chunk holds it, so the
  same sources give the same digest in another directory or on another
  machine. Only a whole path prefix is swapped: with the root `/ci/app`,
  `/ci/app/lib/a.ex` changes and `/ci/app2/lib/a.ex` does not.

  The swap cannot reach a hash of a path. `embed_templates` of
  `Phoenix.Template` defines `__mix_recompile__?/0` with the md5 of the
  absolute paths of the templates as a literal, which is why the recompilation
  hooks are left out.

  A module without that chunk (compiled with `debug_info: false`, stripped, or
  written in Erlang) falls back to `:beam_lib.md5/1`.
  """

  @positional [
    :line,
    :column,
    :counter,
    :version,
    :keep,
    :file,
    :end,
    :do,
    :closing,
    :end_of_expression,
    :newlines,
    :indentation,
    :delimiter,
    :token,
    :format
  ]

  @unstable [:definitions, :file, :relative_file, :anno, :compile_opts]
  @tokens ~r/[A-Za-z0-9_]+|[^A-Za-z0-9_]/s
  @root "$TIA_ROOT"

  # Hooks called by Mix (`__mix_recompile__?/0`) and by the `:phoenix` compiler
  # of Phoenix up to 1.6 (`__phoenix_recompile__?/0`) to decide whether to
  # recompile the module. Phoenix.Template inlines there an md5 of absolute
  # template paths.
  @recompile_hooks [{:__mix_recompile__?, 0}, {:__phoenix_recompile__?, 0}]

  defguardp is_proper(list) when length(list) >= 0

  @doc """
  The digest of the `.beam` file at `path`, in lowercase hexadecimal, or
  `:error` when the file is missing or is not a BEAM file.

  `root` is the root of the project the module was compiled in. When given,
  the digest does not depend on where that directory is.
  """
  @spec digest(Path.t(), Path.t() | nil) :: {:ok, String.t()} | :error
  def digest(path, root \\ nil) do
    path = String.to_charlist(path)

    case :beam_lib.chunks(path, [:debug_info]) do
      {:ok, {module, [debug_info: {:debug_info_v1, :elixir_erl, {:elixir_v1, info, _specs}}]}}
      when is_map(info) ->
        {:ok, hash(:erlang.md5(encode(module, relocate(info, root))))}

      _no_elixir_debug_info ->
        md5(path)
    end
  end

  defp md5(path) do
    case :beam_lib.md5(path) do
      {:ok, {_module, md5}} -> {:ok, hash(md5)}
      {:error, :beam_lib, _reason} -> :error
    end
  end

  defp hash(binary), do: Base.encode16(binary, case: :lower)

  defp relocate(info, nil), do: info

  defp relocate(info, root) do
    root = Path.expand(root)
    # The root as a whole path prefix: not followed by more of a file name.
    pattern = Regex.compile!(Regex.escape(root) <> "(?![A-Za-z0-9_.~-])")
    swap(info, {root, pattern})
  end

  defp swap(binary, {root, pattern}) when is_binary(binary) do
    if :binary.match(binary, root) == :nomatch,
      do: binary,
      else: Regex.replace(pattern, binary, @root)
  end

  defp swap([head | _] = list, root) when is_integer(head) and is_proper(list) do
    if Enum.all?(list, &is_integer/1), do: swap_charlist(list, root), else: swap_list(list, root)
  end

  defp swap([_ | _] = list, root), do: swap_list(list, root)

  defp swap(tuple, root) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> swap_list(root) |> List.to_tuple()

  defp swap(map, root) when is_map(map),
    do:
      map |> Map.to_list() |> Map.new(fn {key, value} -> {swap(key, root), swap(value, root)} end)

  defp swap(leaf, _root), do: leaf

  defp swap_list([head | tail], root), do: [swap(head, root) | swap_list(tail, root)]
  defp swap_list(tail, root), do: swap(tail, root)

  defp swap_charlist(list, root) do
    with binary when is_binary(binary) <- :unicode.characters_to_binary(list),
         swapped when swapped != binary <- swap(binary, root) do
      String.to_charlist(swapped)
    else
      _not_text_or_unchanged -> list
    end
  end

  defp encode(module, info) do
    definitions =
      info
      |> Map.get(:definitions, [])
      |> Enum.reject(&recompile_hook?/1)
      |> Enum.map(&definition/1)
      |> Enum.sort()

    rest = info |> Map.drop(@unstable) |> canon()
    :erlang.term_to_binary({module, rest, definitions}, [:deterministic])
  end

  defp recompile_hook?({name_arity, _kind, _meta, _clauses}), do: name_arity in @recompile_hooks
  defp recompile_hook?(_other), do: false

  defp definition({name_arity, kind, meta, clauses}),
    do: {name_arity, kind, meta(meta), clauses |> Enum.map(&clause/1) |> Enum.sort()}

  defp definition(other), do: canon(other)

  defp clause({meta, args, guards, body}) when is_proper(args) and is_proper(guards),
    do: {meta(meta), Enum.map(args, &canon/1), Enum.map(guards, &canon/1), canon(body)}

  defp clause(other), do: canon(other)

  # A map: `%{a: 1, b: 2}`.
  defp canon({:%{}, meta, args}) when is_proper(meta) and is_proper(args),
    do: {:%{}, meta(meta), args |> Enum.reject(&fingerprint?/1) |> unordered()}

  # Any other call, block or special form: the arguments keep their order.
  defp canon({form, meta, args}) when is_proper(meta) and is_proper(args),
    do: {canon(form), meta(meta), {:ordered, Enum.map(args, &canon/1)}}

  # A variable.
  defp canon({name, meta, context}) when is_proper(meta) and is_atom(context),
    do: {canon(name), meta(meta), context}

  defp canon(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&canon/1) |> List.to_tuple()

  defp canon(list) when is_proper(list) do
    if clauses?(list), do: {:ordered, Enum.map(list, &canon/1)}, else: unordered(list)
  end

  defp canon([head | tail]), do: {:improper, canon(head), canon(tail)}

  defp canon(map) when is_map(map), do: {:map, map |> Map.to_list() |> unordered()}

  # Keeps `1` and `1.0` apart when sorting: they compare equal as terms.
  defp canon(float) when is_float(float), do: {:float, <<float::float>>}
  defp canon(leaf), do: leaf

  defp unordered(list), do: list |> Enum.flat_map(&element/1) |> Enum.sort()

  # A string becomes a marker plus its words and punctuation.
  defp element(binary) when is_binary(binary),
    do: [:string | for([token] <- Regex.scan(@tokens, binary), do: {:token, token})]

  defp element(other), do: [canon(other)]

  defp fingerprint?({:fingerprint, value}), do: is_integer(value)
  defp fingerprint?(_pair), do: false

  defp meta(meta) when is_proper(meta) do
    meta
    |> Enum.reject(fn
      {key, _value} -> key in @positional
      _other -> false
    end)
    |> unordered()
  end

  defp meta(other), do: canon(other)

  # The clauses of `fn`, `case`, `cond`, `receive`, `with` and `try`.
  defp clauses?([_ | _] = list), do: Enum.all?(list, &match?({:->, _meta, [_, _]}, &1))
  defp clauses?([]), do: false
end
