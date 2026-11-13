defmodule Tia.BeamTest do
  # Not async: the fixtures need the `:debug_info` compiler option, which is
  # global and which `mix test` turns off.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    previous = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)
    on_exit(fn -> Code.put_compiler_option(:debug_info, previous) end)
  end

  # Compiles `source` and writes the `.beam` of its only module to `dir/name.beam`,
  # leaving nothing loaded so the same module can be compiled again.
  defp compile(dir, name, source) do
    [{module, binary}] = Code.compile_string(source, "lib/#{name}.ex")
    :code.purge(module)
    :code.delete(module)
    write(dir, name, binary)
  end

  defp write(dir, name, binary) do
    path = Path.join(dir, "#{name}.beam")
    File.write!(path, binary)
    path
  end

  # What a HEEx component does with its slots: it walks a map, and the map
  # hands the keys back in the order their atoms were created, which differs
  # between two compilations. Here the order is given explicitly.
  defp component(module, slots, label \\ "slot") do
    """
    defmodule #{module}.Slots do
      defmacro slots(names) do
        pairs = for name <- names, do: {name, quote(do: fn value -> {unquote(name), value} end)}
        quote do: %{unquote_splicing(pairs)}
      end
    end

    defmodule #{module}.View do
      require #{module}.Slots

      def render(assigns) do
        slots = #{module}.Slots.slots(#{inspect(slots)})
        for {name, slot} <- slots, do: {#{inspect(label)}, name, slot.(assigns)}
      end
    end
    """
  end

  defp view(dir, name, source) do
    modules = Code.compile_string(source, "lib/#{name}.ex")

    for {module, _binary} <- modules do
      :code.purge(module)
      :code.delete(module)
    end

    {_module, binary} =
      Enum.find(modules, fn {module, _} -> List.last(Module.split(module)) == "View" end)

    write(dir, name, binary)
  end

  defp md5(path) do
    {:ok, {_module, md5}} = :beam_lib.md5(String.to_charlist(path))
    Base.encode16(md5, case: :lower)
  end

  test "the same source with its lambdas emitted in another order has the same digest",
       %{tmp_dir: dir} do
    first = view(dir, "first", component("Tia.BeamTest.Slotted", [:col, :actions, :empty]))
    second = view(dir, "second", component("Tia.BeamTest.Slotted", [:empty, :actions, :col]))

    assert md5(first) != md5(second)
    assert {:ok, digest} = Tia.Beam.digest(first)
    assert {:ok, ^digest} = Tia.Beam.digest(second)
  end

  test "a different macro expansion has a different digest", %{tmp_dir: dir} do
    first = view(dir, "first", component("Tia.BeamTest.Expanded", [:col, :actions]))
    more = view(dir, "more", component("Tia.BeamTest.Expanded", [:col, :actions, :empty]))
    other = view(dir, "other", component("Tia.BeamTest.Expanded", [:col, :actions], "cell"))

    assert {:ok, digest} = Tia.Beam.digest(first)
    assert {:ok, more_digest} = Tia.Beam.digest(more)
    assert {:ok, other_digest} = Tia.Beam.digest(other)
    assert digest != more_digest
    assert digest != other_digest
  end

  test "moving the code to other lines keeps the digest, changing a value does not",
       %{tmp_dir: dir} do
    source = fn prefix, value ->
      "#{prefix}defmodule Tia.BeamTest.Lines do\n  def value(a, b), do: {a, b, #{value}}\nend"
    end

    assert {:ok, digest} = Tia.Beam.digest(compile(dir, "a", source.("", 10)))
    assert {:ok, ^digest} = Tia.Beam.digest(compile(dir, "b", source.("\n\n# moved\n", 10)))
    assert {:ok, changed} = Tia.Beam.digest(compile(dir, "c", source.("", 2000)))
    assert changed != digest
  end

  test "the order of the arguments, of the expressions and of the fn clauses counts",
       %{tmp_dir: dir} do
    source = fn body ->
      "defmodule Tia.BeamTest.Ordered do\n  def run(a, b) do\n#{body}\n  end\nend"
    end

    digests =
      for {name, body} <- [
            minus: "a - b",
            reversed: "b - a",
            block: "send(self(), a)\nsend(self(), b)",
            block_reversed: "send(self(), b)\nsend(self(), a)",
            clauses: "case a do\n1 -> b\n2 -> a\nend",
            clauses_reversed: "case a do\n2 -> a\n1 -> b\nend"
          ] do
        {:ok, digest} = Tia.Beam.digest(compile(dir, Atom.to_string(name), source.(body)))
        digest
      end

    assert digests == Enum.uniq(digests)
  end

  # A module that embeds the path of its file the ways a Phoenix macro does:
  # as a string, inside a longer string and as a charlist.
  defp located(value) do
    """
    defmodule Tia.BeamTest.Located do
      @charlist String.to_charlist(__ENV__.file)
      @env Macro.escape(%{file: __ENV__.file, line: __ENV__.line})
      def file, do: __ENV__.file
      def message, do: "defined in " <> unquote(__ENV__.file) <> ", really"
      def charlist, do: @charlist
      def env, do: @env
      def value, do: #{value}
    end
    """
  end

  defp compile_in(root, name, source) do
    File.mkdir_p!(Path.join(root, "ebin"))
    [{module, binary}] = Code.compile_string(source, Path.join(root, "lib/located.ex"))
    :code.purge(module)
    :code.delete(module)
    write(Path.join(root, "ebin"), name, binary)
  end

  test "a module that embeds __ENV__.file has the same digest in another checkout",
       %{tmp_dir: dir} do
    here = Path.join(dir, "home/alex/app")
    there = Path.join(dir, "ci/build")
    first = compile_in(here, "first", located(1))
    second = compile_in(there, "second", located(1))

    assert {:ok, digest} = Tia.Beam.digest(first, here)
    assert {:ok, ^digest} = Tia.Beam.digest(second, there)

    # Without the root, or with a wrong one, the path is part of the digest.
    assert {:ok, bare} = Tia.Beam.digest(first)
    assert {:ok, other_bare} = Tia.Beam.digest(second)
    assert bare != other_bare
    assert {:ok, ^bare} = Tia.Beam.digest(first, there)
    assert bare != digest

    # The rest of the code still counts.
    assert {:ok, changed} = Tia.Beam.digest(compile_in(there, "changed", located(2)), there)
    assert changed != digest
  end

  test "only a whole path prefix is taken for the root", %{tmp_dir: dir} do
    root = Path.join(dir, "app")
    inside = compile_in(root, "inside", located(1))
    sibling = compile_in(root <> "2", "sibling", located(1))
    nested = compile_in(Path.join(root, "apps/web"), "nested", located(1))

    assert {:ok, digest} = Tia.Beam.digest(inside, root)
    assert {:ok, sibling_digest} = Tia.Beam.digest(sibling, root)
    assert {:ok, nested_digest} = Tia.Beam.digest(nested, root)
    assert sibling_digest != digest
    assert nested_digest != digest
    assert {:ok, ^sibling_digest} = Tia.Beam.digest(sibling)
    assert {:ok, ^digest} = Tia.Beam.digest(sibling, root <> "2")
  end

  # What `embed_templates` leaves in a module: a hook for Mix that compares an
  # md5 of the absolute paths of the templates, taken at compile time, with the
  # current one. The md5 is a binary the swap of the root cannot reach.
  defp hooked(hook, value) do
    """
    defmodule Tia.BeamTest.Hooked do
      def #{hook}(), do: unquote(:erlang.md5(__ENV__.file)) != :erlang.md5(__ENV__.file)
      def stale?(), do: #{hook}()
      def value, do: #{value}
    end
    """
  end

  for hook <- ["__mix_recompile__?", "__phoenix_recompile__?"] do
    test "the path hash of #{hook}/0 is left out of the digest", %{tmp_dir: dir} do
      hook = unquote(hook)
      here = Path.join(dir, "home/alex/app")
      there = Path.join(dir, "ci/build")
      first = compile_in(here, "first", hooked(hook, 1))
      second = compile_in(there, "second", hooked(hook, 1))

      assert {:ok, digest} = Tia.Beam.digest(first, here)
      assert {:ok, ^digest} = Tia.Beam.digest(second, there)

      # A function with any other name keeps its hash, and so its path.
      plain = compile_in(here, "plain", hooked("recompile?", 1))
      other_plain = compile_in(there, "other_plain", hooked("recompile?", 1))
      assert {:ok, plain_digest} = Tia.Beam.digest(plain, here)
      assert {:ok, other_plain_digest} = Tia.Beam.digest(other_plain, there)
      assert plain_digest != other_plain_digest

      # The rest of the module still counts.
      assert {:ok, changed} =
               Tia.Beam.digest(compile_in(there, "changed", hooked(hook, 2)), there)

      assert changed != digest
    end
  end

  test "a beam without Elixir debug info falls back to its md5", %{tmp_dir: dir} do
    path = compile(dir, "full", "defmodule Tia.BeamTest.Stripped, do: def(value, do: 1)")
    {:ok, {_module, stripped}} = :beam_lib.strip(File.read!(path))
    stripped_path = write(dir, "stripped", stripped)

    assert {:ok, digest} = Tia.Beam.digest(stripped_path)
    assert digest == md5(stripped_path)
    assert {:ok, full} = Tia.Beam.digest(path)
    assert full != md5(path)

    forms = [
      {:attribute, 1, :module, :tia_beam_test_erlang},
      {:attribute, 1, :export, [value: 0]},
      {:function, 1, :value, 0, [{:clause, 1, [], [], [{:integer, 1, 1}]}]}
    ]

    {:ok, :tia_beam_test_erlang, erlang} = :compile.forms(forms, [:debug_info])
    erlang_path = write(dir, "erlang", erlang)
    assert Tia.Beam.digest(erlang_path) == {:ok, md5(erlang_path)}
  end

  test "a missing or broken file is an error", %{tmp_dir: dir} do
    assert Tia.Beam.digest(Path.join(dir, "nope.beam")) == :error
    assert Tia.Beam.digest(write(dir, "broken", "not a beam")) == :error
  end
end
