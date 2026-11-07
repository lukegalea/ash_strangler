# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Estate.Report do
  @moduledoc """
  An evaluated estate: every catalog relation with its disposition, every
  column with its claims and declaration, and every problem found. Built by
  `AshStrangler.Estate.evaluate/1`; a plug-in's `check/1` receives one.

  `relations` maps `"schema.table"` to

      %{
        kind: "table",                     # the catalog's relation kind
        declared: %Disposition{} | nil,    # a whole-relation declaration
        columns: %{
          "column" => %{
            claims: [%Claim{}],            # computed: mapped, secret, plug-in kinds
            declared: %Disposition{} | nil,
            writers: [module()]            # resources whose mappings write it
          }
        }
      }

  A `problem` is `%{check: atom(), subject: String.t() | nil, message: String.t()}`;
  `subject` is the relation, column, foreign key or declaration id it is about.
  The estate is clean when `problems == []`.
  """

  alias AshStrangler.{Estate, Info, Lens, Snapshot, Twin}
  alias AshStrangler.Estate.{Claim, Disposition, Phases}

  defstruct [
    :estate,
    :catalog_path,
    :catalog_sha256,
    relations: %{},
    residue: [],
    open_references: [],
    problems: []
  ]

  @type problem :: %{check: atom(), subject: String.t() | nil, message: String.t()}
  @type t :: %__MODULE__{
          estate: module(),
          catalog_path: String.t(),
          catalog_sha256: String.t() | nil,
          relations: %{String.t() => map()},
          residue: [AshStrangler.Estate.Residue.t()],
          open_references: [AshStrangler.Estate.OpenReference.t()],
          problems: [problem()]
        }

  @format "ash_strangler.estate/1"

  @doc false
  @spec build(module()) :: t()
  def build(estate) do
    path = Estate.snapshot(estate)

    base = %__MODULE__{
      estate: estate,
      catalog_path: path,
      residue: Estate.residue(estate),
      open_references: Estate.open_references(estate)
    }

    with {:ok, bytes} <- read(path),
         {:ok, catalog} <- Snapshot.read_catalog(path) do
      build(%{base | catalog_sha256: sha256(bytes)}, catalog)
    else
      {:error, message} -> %{base | problems: [problem(:declarations, path, message)]}
    end
  end

  defp build(report, catalog) do
    estate = report.estate
    declaration_problems = declaration_problems(estate, catalog)
    {claims, writers, resource_problems} = resource_claims(Estate.resources(estate), catalog)
    {plugin_claims, claim_problems} = plugin_claims(estate, catalog)
    # A twin both listed and used as a source would otherwise claim its secrets twice.
    claims = Enum.uniq(claims ++ plugin_claims)

    report = %{
      report
      | relations: relations(catalog, Estate.dispositions(estate), claims, writers)
    }

    problems =
      declaration_problems ++
        resource_problems ++
        claim_problems ++
        coverage_problems(report) ++
        writer_problems(report) ++
        reference_problems(report, catalog) ++
        Phases.problems(report, Phases.entries(Estate.resources(estate))) ++
        AshStrangler.Estate.Tenancy.problems(Estate.resources(estate), catalog)

    report = %{report | problems: problems}
    %{report | problems: problems ++ plugin_problems(report)}
  end

  # --- declarations (also VerifyEstate) ----------------------------------

  @doc """
  The checks that need only the estate's declarations and the catalog. Shared
  with `AshStrangler.Verifiers.VerifyEstate`, which runs them at compile time.
  """
  @spec declaration_problems(module() | Spark.Dsl.t(), map()) :: [problem()]
  def declaration_problems(estate, catalog) do
    dispositions = Estate.dispositions(estate)
    relations = catalog["relations"] || %{}

    resolved = Enum.map(dispositions, &{&1, resolve(&1.id, relations)})

    unknown =
      for {disposition, :error} <- resolved do
        problem(
          :declarations,
          disposition.id,
          "`#{disposition.kind} #{inspect(disposition.id)}`: the catalog has no relation or " <>
            "column #{inspect(disposition.id)}."
        )
      end

    carried_tables =
      for {%{kind: :carried} = disposition, {:relation, _}} <- resolved do
        problem(
          :declarations,
          disposition.id,
          "`carried #{inspect(disposition.id)}`: `carried` applies to a column, and " <>
            "#{inspect(disposition.id)} is a relation."
        )
      end

    twice =
      resolved
      |> Enum.reject(&match?({_, :error}, &1))
      |> Enum.group_by(fn {_disposition, target} -> target end, &elem(&1, 0))
      |> Enum.filter(fn {_target, list} -> length(list) > 1 end)
      |> Enum.map(fn {_target, [first | _] = list} ->
        problem(
          :declarations,
          first.id,
          "#{inspect(first.id)} is declared #{length(list)} times " <>
            "(#{Enum.map_join(list, ", ", & &1.kind)}). Keep one."
        )
      end)

    whole = for {d, {:relation, relation}} <- resolved, into: %{}, do: {relation, d}

    inside =
      for {disposition, {:column, relation, _column}} <- resolved,
          table = whole[relation] do
        problem(
          :declarations,
          disposition.id,
          "#{inspect(disposition.id)} is declared #{disposition.kind}, but #{inspect(relation)} " <>
            "is declared #{table.kind} as a whole. Declare the relation or its columns, not both."
        )
      end

    unknown ++
      carried_tables ++
      twice ++
      inside ++
      residue_problems(estate, relations) ++
      open_reference_problems(estate, relations)
  end

  defp residue_problems(estate, relations) do
    residue = Estate.residue(estate)

    in_catalog =
      for %{relation: relation} <- residue, Map.has_key?(relations, relation) do
        problem(
          :declarations,
          relation,
          "residue #{inspect(relation)} is in the catalog. Residue names a relation a live " <>
            "database may carry that the catalog does not; declare a catalog relation " <>
            "`dead` instead."
        )
      end

    in_catalog ++ duplicates(residue, & &1.relation, "residue")
  end

  defp open_reference_problems(estate, relations) do
    references = Estate.open_references(estate)

    unknown =
      for %{id: id} <- references, foreign_key(id, relations) == :error do
        problem(
          :declarations,
          id,
          "`open_reference #{inspect(id)}`: the catalog has no foreign key #{inspect(id)} " <>
            "(\"schema.table.constraint_name\")."
        )
      end

    unknown ++ duplicates(references, & &1.id, "open_reference")
  end

  defp duplicates(entries, key, what) do
    entries
    |> Enum.frequencies_by(key)
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, count} ->
      problem(:declarations, id, "#{what} #{inspect(id)} is declared #{count} times.")
    end)
  end

  @doc false
  # "schema.table" or "schema.table.column", resolved against the catalog.
  @spec resolve(String.t(), map()) ::
          {:relation, String.t()} | {:column, String.t(), String.t()} | :error
  def resolve(id, relations) do
    if Map.has_key?(relations, id) do
      {:relation, id}
    else
      with {:ok, relation, column} <- split(id, relations),
           true <- Enum.any?(relations[relation]["columns"], &(&1["name"] == column)) do
        {:column, relation, column}
      else
        _ -> :error
      end
    end
  end

  defp foreign_key(id, relations) do
    with {:ok, relation, name} <- split(id, relations),
         %{} = key <- Enum.find(relations[relation]["foreign_keys"] || [], &(&1["name"] == name)) do
      {:ok, relation, key}
    else
      _ -> :error
    end
  end

  # The relation whose name prefixes `id`, and the rest. Identifiers may
  # contain dots, so this matches catalog keys rather than splitting.
  defp split(id, relations) do
    Enum.find_value(relations, :error, fn {relation, _} ->
      prefix = relation <> "."

      if String.starts_with?(id, prefix) and byte_size(id) > byte_size(prefix),
        do: {:ok, relation, binary_part(id, byte_size(prefix), byte_size(id) - byte_size(prefix))}
    end)
  end

  # --- computed claims ---------------------------------------------------

  defp resource_claims(resources, catalog) do
    resources
    |> Enum.map(&resource_claims_for(&1, catalog))
    |> Enum.reduce({[], [], []}, fn {c, w, p}, {cs, ws, ps} -> {cs ++ c, ws ++ w, ps ++ p} end)
  end

  defp resource_claims_for(module, catalog) do
    cond do
      not Code.ensure_loaded?(module) ->
        {[], [], [problem(:resources, inspect(module), "#{inspect(module)} is not compiled.")]}

      AshStrangler.Migration.union?(module) ->
        union_claims(module, catalog)

      AshStrangler.Migration.derived?(module) ->
        derived_claims(module, catalog)

      function_exported?(module, :spark_dsl_config, 0) and Info.strangled?(module) ->
        strangled_claims(module, catalog)

      Twin.twin?(module) ->
        {secret_claims([module]), [], []}

      true ->
        {[], [],
         [
           problem(
             :resources,
             inspect(module),
             "#{inspect(module)} is neither a strangled resource nor a twin."
           )
         ]}
    end
  end

  defp strangled_claims(resource, catalog) do
    twin = Info.twin(resource)
    joins = Info.joins(resource)

    read =
      for lens <- Lens.for_resource(resource),
          {path, attribute} <- lens.sources,
          {:ok, at} <- [Twin.resource_at(twin, path)],
          Ash.Resource.Info.attribute(at, attribute) != nil do
        {relation(at), Twin.column!(at, attribute)}
      end

    joined =
      for %{relationship: rel} <- joins,
          {side, attribute} <- [
            {rel.source, rel.source_attribute},
            {rel.destination, rel.destination_attribute}
          ] do
        {relation(side), Twin.column!(side, attribute)}
      end

    claims =
      for {relation, column} <- Enum.uniq(read ++ joined) do
        %Claim{relation: relation, column: column, kind: :mapped, by: resource}
      end

    writers =
      for lens <- Lens.for_resource(resource),
          not lens.read_only?,
          {attribute, _expression} <- lens.writes,
          uniq: true do
        {relation(twin), Twin.column!(twin, attribute), resource}
      end

    twins = Enum.uniq([twin | Enum.map(joins, & &1.relationship.destination)])
    claims = claims ++ secret_claims(twins)
    {claims, writers, missing_columns(claims, catalog, resource)}
  end

  # Each legacy branch reads its twin through its key and its mappings; a
  # `:dual_write` branch writes the columns it renames.
  defp union_claims(union, catalog) do
    branches = AshStrangler.Union.Info.branches(union)

    read =
      for branch <- branches, {attribute, twin} <- branch_reads(branch) do
        {relation(twin), Twin.column!(twin, attribute)}
      end

    claims =
      for {relation, column} <- Enum.uniq(read) do
        %Claim{relation: relation, column: column, kind: :mapped, by: union}
      end

    writers =
      for %{phase: :dual_write, twin: twin} = branch <- branches,
          attribute <- branch_writes(branch),
          uniq: true do
        {relation(twin), Twin.column!(twin, attribute), union}
      end

    claims = claims ++ secret_claims(Enum.uniq(Enum.map(branches, & &1.twin)))
    {claims, writers, missing_columns(claims, catalog, union)}
  end

  # A derived view reads its twin through its key columns, its filters and its
  # mappings. It writes nothing.
  defp derived_claims(derived, catalog) do
    alias AshStrangler.Derived.Info, as: DerivedInfo

    twin = DerivedInfo.twin(derived)
    sources = DerivedInfo.sources(derived)

    mapped = for source <- sources, mapping <- source.mappings, a <- mapping_reads(mapping), do: a

    filtered =
      for expression <- [DerivedInfo.filter(derived) | Enum.map(sources, & &1.filter)],
          expression != nil,
          {[], attribute} <- AshStrangler.Expr.refs(expression),
          do: attribute

    jsonb = for %{kind: :element, from: from} <- sources, do: from

    claims =
      for attribute <- Enum.uniq(DerivedInfo.from(derived) ++ mapped ++ filtered ++ jsonb) do
        %Claim{
          relation: relation(twin),
          column: Twin.column!(twin, attribute),
          kind: :mapped,
          by: derived
        }
      end

    claims = claims ++ secret_claims([twin])
    {claims, [], missing_columns(claims, catalog, derived)}
  end

  defp branch_reads(%{twin: twin, keys: keys, mappings: mappings} = branch) do
    key_attrs = Enum.flat_map(keys, &AshStrangler.Key.columns/1)

    mapped = Enum.flat_map(mappings, &mapping_reads/1)

    filtered =
      case Map.get(branch, :filter) do
        nil -> []
        filter -> for {[], attribute} <- AshStrangler.Expr.refs(filter), do: attribute
      end

    for attribute <- Enum.uniq(key_attrs ++ mapped ++ filtered), do: {attribute, twin}
  end

  defp mapping_reads(%AshStrangler.Union.TenantKey{} = key),
    do: AshStrangler.Union.TenantKey.columns(key)

  defp mapping_reads(%{from: from}) when is_atom(from), do: [from]

  defp mapping_reads(%{from: from}),
    do: for({[], attribute} <- AshStrangler.Expr.refs(from), do: attribute)

  defp mapping_reads(_other), do: []

  defp branch_writes(%{mappings: mappings}) do
    for %{from: from} <- mappings,
        attribute <-
          (if is_atom(from) do
             [from]
           else
             case AshStrangler.Expr.simple_reference(from) do
               {:ok, attribute} -> [attribute]
               :error -> []
             end
           end),
        do: attribute
  end

  defp secret_claims(twins) do
    for twin <- twins, column <- Twin.secrets(twin) do
      %Claim{relation: relation(twin), column: column, kind: :secret, by: twin}
    end
  end

  defp missing_columns(claims, catalog, resource) do
    relations = catalog["relations"] || %{}

    for %Claim{relation: relation, column: column} <- claims,
        not column?(relations, relation, column),
        uniq: true do
      subject = "#{relation}.#{column}"

      problem(
        :resources,
        subject,
        "#{inspect(resource)} reads #{subject}, which the catalog does not have. The twin is " <>
          "stale against #{relation}'s snapshot, or the estate covers a different catalog."
      )
    end
  end

  defp plugin_claims(estate, catalog) do
    relations = catalog["relations"] || %{}
    reserved = Claim.reserved_kinds()

    estate
    |> Estate.plugins()
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :claims, 2)))
    |> Enum.flat_map(fn plugin -> Enum.map(plugin.claims(estate, catalog), &{plugin, &1}) end)
    |> Enum.reduce({[], []}, fn {plugin, claim}, {claims, problems} ->
      cond do
        not is_struct(claim, Claim) or not is_atom(claim.kind) ->
          {claims,
           problems ++
             [
               problem(
                 :claims,
                 inspect(plugin),
                 "#{inspect(plugin)}.claims/2 returned #{inspect(claim)}, not an " <>
                   "%AshStrangler.Estate.Claim{} with an atom kind."
               )
             ]}

        claim.kind in reserved ->
          {claims,
           problems ++
             [
               problem(
                 :claims,
                 "#{claim.relation}.#{claim.column}",
                 "#{inspect(plugin)} claims #{claim.relation}.#{claim.column} as " <>
                   "#{inspect(claim.kind)}, a kind the estate reserves " <>
                   "(#{Enum.map_join(reserved, ", ", &inspect/1)})."
               )
             ]}

        not column?(relations, claim.relation, claim.column) ->
          {claims,
           problems ++
             [
               problem(
                 :claims,
                 "#{claim.relation}.#{claim.column}",
                 "#{inspect(plugin)} claims #{claim.relation}.#{claim.column}, which the " <>
                   "catalog does not have."
               )
             ]}

        true ->
          {claims ++ [claim], problems}
      end
    end)
  end

  # --- the relation table ------------------------------------------------

  defp relations(catalog, dispositions, claims, writers) do
    relations = catalog["relations"] || %{}
    resolved = Enum.map(dispositions, &{&1, resolve(&1.id, relations)})
    claims = Enum.group_by(claims, &{&1.relation, &1.column})

    writers =
      Enum.group_by(writers, fn {r, c, _} -> {r, c} end, fn {_, _, w} -> w end)

    Map.new(relations, fn {name, relation} ->
      declared = Enum.find_value(resolved, fn {d, target} -> target == {:relation, name} && d end)

      columns =
        Map.new(relation["columns"], fn %{"name" => column} ->
          {column,
           %{
             claims: Map.get(claims, {name, column}, []),
             declared:
               Enum.find_value(resolved, fn {d, target} ->
                 target == {:column, name, column} && d
               end),
             writers: writers |> Map.get({name, column}, []) |> Enum.uniq()
           }}
        end)

      {name, %{kind: relation["kind"], declared: declared, columns: columns}}
    end)
  end

  # --- coverage and consistency -------------------------------------------

  defp coverage_problems(report) do
    report.relations
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, relation} -> relation_coverage(name, relation) end)
  end

  defp relation_coverage(name, %{declared: %Disposition{} = table, columns: columns}) do
    for {column, %{claims: [_ | _] = claims}} <- Enum.sort(columns) do
      problem(
        :consistency,
        "#{name}.#{column}",
        "#{inspect(name)} is declared #{table.kind} as a whole, but #{name}.#{column} is " <>
          "#{describe_claims(claims)}. A relation the strangle reads cannot be declared as a " <>
          "whole: give each of its columns a disposition instead."
      )
    end
  end

  defp relation_coverage(name, %{columns: columns}) do
    unaccounted = for {c, %{claims: [], declared: nil}} <- columns, do: c

    conflicts =
      for {column, %{claims: [_ | _] = claims, declared: %Disposition{} = d}} <-
            Enum.sort(columns) do
        problem(
          :coverage,
          "#{name}.#{column}",
          "#{name}.#{column} is declared #{d.kind}, but it is also #{describe_claims(claims)}. " <>
            "A column has exactly one disposition: drop the declaration, or stop reading it."
        )
      end

    missing =
      cond do
        unaccounted == [] ->
          []

        length(unaccounted) == map_size(columns) ->
          [
            problem(
              :coverage,
              name,
              "#{inspect(name)} has no disposition (#{map_size(columns)} columns). Map it, or " <>
                "declare the relation deferred, legacy_only or dead, or give each column a " <>
                "disposition."
            )
          ]

        true ->
          for column <- Enum.sort(unaccounted) do
            problem(
              :coverage,
              "#{name}.#{column}",
              "#{name}.#{column} has no disposition. Map it, claim it in a plug-in, or " <>
                "declare it carried, deferred, legacy_only or dead."
            )
          end
      end

    conflicts ++ missing
  end

  defp describe_claims(claims) do
    claims
    |> Enum.group_by(& &1.kind, &inspect_by(&1.by))
    |> Enum.sort()
    |> Enum.map_join(" and ", fn {kind, by} -> "#{kind} by #{Enum.join(Enum.uniq(by), ", ")}" end)
  end

  # --- writers -----------------------------------------------------------

  defp writer_problems(report) do
    for {name, relation} <- Enum.sort_by(report.relations, &elem(&1, 0)),
        {column, %{writers: [_, _ | _] = writers}} <- Enum.sort(relation.columns) do
      problem(
        :writers,
        "#{name}.#{column}",
        "#{name}.#{column} is written by #{Enum.map_join(writers, " and ", &inspect/1)}. " <>
          "Two resources writing one legacy column overwrite each other; make all but one " <>
          "mapping `read_only? true`."
      )
    end
  end

  # --- references --------------------------------------------------------

  defp reference_problems(report, catalog) do
    open = Map.new(report.open_references, &{&1.id, &1})

    for {name, relation} <- Enum.sort(catalog["relations"] || %{}),
        key <- relation["foreign_keys"] || [],
        problem = reference_problem(report, name, key, open[name <> "." <> key["name"]]),
        do: problem
  end

  defp reference_problem(report, name, key, open) do
    id = "#{name}.#{key["name"]}"
    mapped? = Enum.any?(key["columns"], &mapped?(report, name, &1))
    target = key["references"]["relation"]

    unclaimed =
      Enum.filter(key["references"]["columns"], fn column ->
        get_in(report.relations, [target, :columns, column, :claims]) in [nil, []]
      end)

    cond do
      not mapped? and open ->
        problem(
          :references,
          id,
          "open_reference #{inspect(id)} is not needed: #{name}(#{Enum.join(key["columns"], ", ")}) " <>
            "is not mapped. Remove it."
        )

      not mapped? ->
        nil

      unclaimed == [] and key["validated"] and open ->
        problem(
          :references,
          id,
          "open_reference #{inspect(id)} is not needed: the key is validated and " <>
            "#{target}(#{Enum.join(key["references"]["columns"], ", ")}) is mapped or claimed. " <>
            "Remove it."
        )

      unclaimed == [] and key["validated"] ->
        nil

      open ->
        nil

      true ->
        reasons =
          Enum.reject(
            [
              unclaimed != [] &&
                "it references #{target}(#{Enum.join(unclaimed, ", ")}), which nothing maps or claims",
              not key["validated"] &&
                "the constraint is NOT VALID, so legacy rows may already dangle"
            ],
            &(&1 == false)
          )

        problem(
          :references,
          id,
          "#{name}(#{Enum.join(key["columns"], ", ")}) is mapped, but foreign key " <>
            "#{inspect(id)} is not closed: #{Enum.join(reasons, "; ")}. Map or claim the " <>
            "target, or declare `open_reference #{inspect(id)}, because: \"...\"`."
        )
    end
  end

  defp mapped?(report, relation, column) do
    report.relations
    |> get_in([relation, :columns, column, :claims])
    |> List.wrap()
    |> Enum.any?(&(&1.kind == :mapped))
  end

  # --- plug-ins ----------------------------------------------------------

  defp plugin_problems(report) do
    for plugin <- Estate.plugins(report.estate),
        Code.ensure_loaded?(plugin) and function_exported?(plugin, :check, 1),
        message <- plugin.check(report) do
      problem(:plugin, inspect(plugin), message)
    end
  end

  # --- manifest ----------------------------------------------------------

  @doc false
  @spec manifest(t()) :: map()
  def manifest(report) do
    relations =
      Map.new(report.relations, fn {name, relation} -> {name, manifest_relation(relation)} end)

    columns =
      for {_name, %{"columns" => columns}} <- relations, {_column, entry} <- columns, do: entry

    %{
      "format" => @format,
      "estate" => inspect(report.estate),
      "catalog" => %{"path" => report.catalog_path, "sha256" => report.catalog_sha256},
      "relations" => relations,
      "residue" => Map.new(report.residue, &{&1.relation, %{"because" => &1.because}}),
      "open_references" => Map.new(report.open_references, &{&1.id, %{"because" => &1.because}}),
      "drift_allow" => Enum.map(report.residue, &"relation #{&1.relation}"),
      "counts" => %{
        "relations" => Enum.frequencies_by(Map.values(relations), & &1["disposition"]),
        "columns" => Enum.frequencies_by(columns, & &1["disposition"])
      },
      "problems" =>
        Enum.map(report.problems, fn problem ->
          %{
            "check" => Atom.to_string(problem.check),
            "subject" => problem.subject,
            "message" => problem.message
          }
        end)
    }
  end

  defp manifest_relation(%{declared: %Disposition{} = declared, kind: kind}) do
    Map.put(declared_entry(declared), "kind", kind)
  end

  defp manifest_relation(%{kind: kind, columns: columns}) do
    %{
      "kind" => kind,
      "disposition" => "columns",
      "columns" => Map.new(columns, fn {name, column} -> {name, manifest_column(column)} end)
    }
  end

  defp manifest_column(%{declared: %Disposition{} = declared, claims: []}),
    do: declared_entry(declared)

  defp manifest_column(%{claims: [], declared: nil}), do: %{"disposition" => "none"}

  defp manifest_column(%{claims: claims, writers: writers} = column) do
    by_kind = Enum.group_by(claims, & &1.kind, &inspect_by(&1.by))

    entry = %{
      "disposition" => by_kind |> Map.keys() |> Enum.sort() |> Enum.join("+"),
      "claims" =>
        Map.new(by_kind, fn {kind, by} ->
          {Atom.to_string(kind), by |> Enum.uniq() |> Enum.sort()}
        end)
    }

    entry =
      if writers == [],
        do: entry,
        else: Map.put(entry, "written_by", Enum.map(writers, &inspect/1))

    case column.declared do
      nil -> entry
      declared -> Map.put(entry, "also_declared", Atom.to_string(declared.kind))
    end
  end

  defp declared_entry(%Disposition{} = d) do
    %{"disposition" => Atom.to_string(d.kind), "because" => d.because}
    |> then(fn entry ->
      if d.kind == :deferred,
        do: Map.merge(entry, %{"wave" => Atom.to_string(d.wave), "target" => d.target}),
        else: entry
    end)
  end

  # --- helpers -----------------------------------------------------------

  defp relation(twin) do
    "#{AshPostgres.DataLayer.Info.schema(twin) || "public"}.#{Twin.table!(twin)}"
  end

  defp column?(relations, relation, column) do
    case relations do
      %{^relation => %{"columns" => columns}} -> Enum.any?(columns, &(&1["name"] == column))
      _ -> false
    end
  end

  defp inspect_by(by) when is_binary(by), do: by
  defp inspect_by(by), do: inspect(by)

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp problem(check, subject, message), do: %{check: check, subject: subject, message: message}
end
