defmodule AletheaTest.ASTScan do
  @moduledoc """
  Shared AST-aware scanner for "sole call/construction site" static
  gates (#229's Sole Constructor Gate, PR #273; #235's Hypothesis
  Wiring Gate). Extracted from `hypothesis_policy_test.exs`'s private
  `hg_walk/2` (design AD5) so a second scanner shape (call-expression
  detection) reuses one audited walker instead of a third copy.

  Every predicate here is AST-aware, never textual/`grep`-style: a
  `@moduledoc`/comment string merely *mentioning* a module or struct
  name in prose is never mistaken for a real construction or call —
  the false-positive class PR #273 fixed.
  """

  @doc """
  Lists `.ex` files under `lib/**/*.ex`, excluding any whose path ends
  with one of the given suffixes.
  """
  @spec lib_files(exclude: [String.t()]) :: [Path.t()]
  def lib_files(opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])

    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, exclude))
  end

  @doc """
  Reads and parses a source file into its AST. Raises on read or
  parse failure — a gate over an unparsable file has already failed.
  """
  @spec parse!(Path.t()) :: Macro.t()
  def parse!(path), do: path |> File.read!() |> Code.string_to_quoted!()

  @doc """
  Walks `ast` distinguishing pattern position (function heads,
  case/with/fn clauses, the left side of `=`/`<-`) from expression
  position, and reports whether `%struct_name{}` is *constructed*
  (expression position) anywhere. Reading/destructuring the struct in
  a pattern is never a violation; only building a new one is.

  Generalizes the original `hg_walk/2`, which hardcoded a single
  struct alias, to any `struct_name`. The match head below matches
  any `%_{}` node and checks the name in its body (rather than in the
  head, as the original did) so non-matching struct literals are
  still walked for nested construction instead of silently skipped.
  """
  @spec constructs_struct?(Macro.t(), atom()) :: boolean()
  def constructs_struct?(ast, struct_name), do: walk_construct(ast, struct_name, false)

  defp walk_construct(
         {:%, _, [{:__aliases__, _, segments}, {:%{}, _, _} = map]},
         struct_name,
         pattern?
       ) do
    if List.last(segments) == struct_name do
      not pattern? or walk_construct(map, struct_name, pattern?)
    else
      walk_construct(map, struct_name, pattern?)
    end
  end

  defp walk_construct({:def, _, [head, body]}, struct_name, _pattern?),
    do: walk_construct(head, struct_name, true) or walk_construct(body, struct_name, false)

  defp walk_construct({:defp, _, [head, body]}, struct_name, _pattern?),
    do: walk_construct(head, struct_name, true) or walk_construct(body, struct_name, false)

  defp walk_construct({:when, _, [head, guard]}, struct_name, true),
    do: walk_construct(head, struct_name, true) or walk_construct(guard, struct_name, false)

  defp walk_construct({:->, _, [args, body]}, struct_name, _pattern?),
    do: walk_construct(args, struct_name, true) or walk_construct(body, struct_name, false)

  defp walk_construct({:=, _, [lhs, rhs]}, struct_name, _pattern?),
    do: walk_construct(lhs, struct_name, true) or walk_construct(rhs, struct_name, false)

  defp walk_construct({:<-, _, [lhs, rhs]}, struct_name, _pattern?),
    do: walk_construct(lhs, struct_name, true) or walk_construct(rhs, struct_name, false)

  defp walk_construct({left, right}, struct_name, pattern?),
    do:
      walk_construct(left, struct_name, pattern?) or
        walk_construct(right, struct_name, pattern?)

  defp walk_construct({_, _, args}, struct_name, pattern?) when is_list(args),
    do: walk_construct(args, struct_name, pattern?)

  defp walk_construct({_, _, _}, _struct_name, _pattern?), do: false

  defp walk_construct(list, struct_name, pattern?) when is_list(list),
    do: Enum.any?(list, &walk_construct(&1, struct_name, pattern?))

  defp walk_construct(_, _struct_name, _pattern?), do: false

  @doc """
  Reports whether `ast` contains a call site targeting a module whose
  alias segments end in `module_suffix` (suffix match, never
  equality — `Alethea....HypothesisPolicy` matches `:HypothesisPolicy`
  the same as a bare `HypothesisPolicy` reference) and one of
  `function_names`. Detects, as call sites:

    * a qualified call expression: `Mod.fun(args)`
    * a capture: `&Mod.fun/arity` (the inner dot node matches the
      same way under the walk)
    * `apply(Mod, :fun, args)`
    * `import Mod` (the only route to an unqualified call)

  Needs no pattern-context tracking, unlike `constructs_struct?/2`: a
  call expression is illegal in pattern position, so there is no
  pattern/expression ambiguity to resolve.
  """
  @spec calls?(Macro.t(), module_suffix :: atom(), [atom()]) :: boolean()
  def calls?(ast, module_suffix, function_names) when is_list(function_names) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        node, true ->
          {node, true}

        {{:., _, [{:__aliases__, _, segments}, fun]}, _, _} = node, false ->
          {node, List.last(segments) == module_suffix and fun in function_names}

        {:apply, _, [{:__aliases__, _, segments}, fun, _args]} = node, false ->
          {node, List.last(segments) == module_suffix and fun in function_names}

        {:import, _, [{:__aliases__, _, segments} | _]} = node, false ->
          {node, List.last(segments) == module_suffix}

        node, false ->
          {node, false}
      end)

    found?
  end
end
