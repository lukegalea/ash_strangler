# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyUnion do
  @moduledoc """
  Compile-time checks on an `AshStrangler.Union`.

    * one `view`, at least one legacy branch and exactly one owned branch;
    * column, branch and key names are unique, and no column is named like the
      key or `__branch`;
    * a branch's twin is a twin, and everything a branch reads is a column of it;
    * a branch has exactly one `key`, a supported strategy over twin columns,
      and answers every column exactly once (`map`, `constant` or `unmapped`);
    * two branches never share a key namespace (their ids would collide).

  Every refusal names the branch and the column.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Expr, Twin}
  alias AshStrangler.Union.{Constant, Info, TenantKey, Unmapped}
  alias AshStrangler.Union.Map, as: MapEntry
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case problems(dsl) do
      [] -> :ok
      [first | _] = all -> {:error, error(dsl, first, all)}
    end
  end

  @doc false
  def problems(dsl) do
    branches = Info.branches(dsl)
    columns = Enum.map(Info.columns(dsl), & &1.name)
    key = Info.key(dsl)

    structure(dsl, branches, columns, key) ++
      Enum.flat_map(branches, &branch_problems(&1, columns, key)) ++ key_collisions(branches)
  end

  defp structure(dsl, branches, columns, key) do
    owned =
      Spark.Dsl.Extension.get_entities(dsl, [:union])
      |> Enum.count(&is_struct(&1, AshStrangler.Union.Owned))

    List.flatten([
      if(is_nil(Info.view(dsl)), do: ["declare the canonical `view`"], else: []),
      if(branches == [], do: ["declare at least one `legacy` branch"], else: []),
      if(owned != 1, do: ["declare exactly one `owned` branch (found #{owned})"], else: []),
      dups(columns, "column"),
      dups(Enum.map(branches, & &1.name), "branch"),
      if(key in columns or key == :__branch,
        do: ["the key column #{inspect(key)} is also declared as a column"],
        else: []
      ),
      if(:__branch in columns, do: ["`__branch` is reserved for the branch name"], else: []),
      if(
        Enum.any?(branches, &(&1.name == :owned)) and owned == 1 and
          Info.owned(dsl).name == :owned,
        do: ["a legacy branch is named like the owned branch"],
        else: []
      )
    ])
  end

  defp dups(names, what) do
    for {name, n} <- Enum.frequencies(names),
        n > 1,
        do: "#{what} #{inspect(name)} is declared #{n} times"
  end

  defp branch_problems(branch, columns, key) do
    at = "branch #{inspect(branch.name)}: "

    if Code.ensure_compiled(branch.twin) == {:module, branch.twin} and Twin.twin?(branch.twin) do
      Enum.map(
        key_problems(branch, key) ++ mapping_problems(branch, columns),
        &(at <> &1)
      ) ++
        if(String.trim(branch.refused_because) == "",
          do: [at <> "`refused_because` is empty"],
          else: []
        )
    else
      [at <> "#{inspect(branch.twin)} is not a twin module"]
    end
  end

  defp key_problems(branch, key) do
    case branch.keys do
      [%{from: from, strategy: strategy}] ->
        missing(branch.twin, List.wrap(from), "key") ++ strategy_problems(strategy, key)

      keys ->
        ["declare exactly one `key` (found #{length(keys)})"]
    end
  end

  defp strategy_problems({:uuid_v5, [namespace: ns]}, _key) when is_binary(ns), do: []
  defp strategy_problems({:uuid_v5, namespace: ns}, _key) when is_binary(ns), do: []

  defp strategy_problems({:uuid_v8, registry, kind}, _key)
       when is_atom(registry) and is_atom(kind),
       do: []

  defp strategy_problems(:identity, _key), do: []
  defp strategy_problems(other, _key), do: ["unsupported key strategy #{inspect(other)}"]

  defp mapping_problems(branch, columns) do
    answered =
      Enum.flat_map(branch.mappings, fn
        %MapEntry{attribute: a} -> [a]
        %Constant{attribute: a} -> [a]
        %TenantKey{attribute: a} -> [a]
        %Unmapped{attributes: as} -> as
      end)

    reads =
      Enum.flat_map(branch.mappings, fn
        %MapEntry{from: from} when is_atom(from) ->
          missing(branch.twin, [from], "map")

        %MapEntry{from: from} ->
          missing(branch.twin, for({[], c} <- Expr.refs(from), do: c), "map")

        %TenantKey{} = key ->
          missing(branch.twin, TenantKey.columns(key), "tenant_of")

        _ ->
          []
      end)

    List.flatten([
      for(a <- answered -- columns, do: "#{inspect(a)} is not a declared column"),
      for(
        c <- columns -- answered,
        do: "column #{inspect(c)} is not answered: `map`, `constant` or `unmapped` it"
      ),
      dups(answered, "mapping for column"),
      reads
    ])
  end

  defp missing(twin, columns, what) do
    attrs = Twin.columns(twin)

    for column <- columns,
        column not in attrs,
        do: "#{what} reads #{inspect(column)}, which #{inspect(twin)} does not have"
  end

  defp key_collisions(branches) do
    branches
    |> Enum.flat_map(fn b ->
      case b.keys do
        [%{strategy: {:uuid_v5, opts}}] -> [{{:v5, opts[:namespace]}, b.name}]
        [%{strategy: {:uuid_v8, registry, kind}}] -> [{{:v8, registry, kind}, b.name}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn
      {_space, [_, _ | _] = names} ->
        [
          "branches #{Enum.map_join(names, ", ", &inspect/1)} share a key namespace, so their ids can collide"
        ]

      _ ->
        []
    end)
  end

  defp error(dsl, first, all) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:union],
      message: """
      #{first}

      All problems:
      #{Enum.map_join(all, "\n", &"  * #{&1}")}
      """
    )
  end
end
