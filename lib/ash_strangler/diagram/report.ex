# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Diagram.Report do
  @moduledoc """
  The mapping written out as Markdown tables: what feeds what, and through what.

  A picture of a mapping has to choose between two failures. Drawn at column
  level it is a tangle past a dozen columns; drawn at relation level it says
  "9 mapped, 3 read only" and nothing a reader can act on. A table has neither
  problem. Each attribute is one row, so a hundred of them stay scannable, and
  every cell can carry the actual text: the legacy column, the SQL the view runs,
  the direction the value travels, and the reason the mapping gave.

  This is what the Clarity tab renders (`AshStrangler.ClarityContent.MappingDiagram`).
  The Mermaid renderers, `AshStrangler.Diagram.Mapping` and
  `AshStrangler.Diagram.Overview`, remain for the README and
  `mix ash_strangler.gen.diagram`, where a picture is what is wanted.

  Nothing is inferred. Every cell is read from `AshStrangler.Lens` and
  `AshStrangler.Info`, the structures the view, the triggers and the reconciler
  are generated from, so the report cannot describe a mapping the database does
  not have.

  ## What a resource section holds

  | Part | Says |
  |---|---|
  | facts | the phase, how writes reach the base table, the view, the legacy relations it reads and how they are joined |
  | attribute table | per attribute: the legacy column(s), the SQL or combinator, the direction a value travels, and the mapping's own `because:` |
  | read only | the attributes that cannot be written back, by name, with the reason |
  | not read | legacy columns no mapping reads, and the columns declared `retired` |

  ## What an application or domain section adds

  A relation-to-resources index, so the fan-out out of one table is visible, and
  a one-row-per-resource summary that names (rather than counts) its read-only and
  unmapped attributes. The per-resource sections follow.

  Needs no optional dependency.
  """

  alias AshStrangler.{Info, Lens, Lineage, Twin}
  alias AshStrangler.Sql.Printer

  @phases [:read_from_legacy, :dual_write, :read_from_new, :decommissioned]
  @sql_limit 240

  @doc "A report for every strangled resource in `applications`."
  @spec for_applications([atom()]) :: String.t()
  def for_applications(applications),
    do: applications |> Enum.flat_map(&Ash.Info.domains/1) |> for_domains()

  @doc "A report for every strangled resource in `domains`."
  @spec for_domains([Ash.Domain.t()]) :: String.t()
  def for_domains(domains),
    do: domains |> Enum.flat_map(&Ash.Domain.Info.resources/1) |> for_resources()

  @doc """
  A report for `resources`. Resources without a `strangler` block are skipped.

  One resource gets its section alone; several get the index and the summary
  first.
  """
  @spec for_resources([Ash.Resource.t()]) :: String.t()
  def for_resources(resources) do
    case Enum.filter(resources, &Info.strangled?/1) do
      [] ->
        "_No resource here has a `strangler` block._\n"

      [resource] ->
        resource_section(resource, "##")

      resources ->
        [
          index(resources),
          summary(resources),
          Enum.map(resources, &resource_section(&1, "##"))
        ]
        |> IO.iodata_to_binary()
    end
  end

  # --- application and domain level -------------------------------------

  # One row per relation-resource pair: raw HTML (a `<br>` in a cell) is dropped
  # by Clarity's Markdown renderer, so a cell never holds a list.
  defp index(resources) do
    rows =
      resources
      |> Enum.flat_map(fn resource ->
        Enum.map(relations(resource), fn {relation, role} -> {relation, resource, role} end)
      end)
      |> Enum.sort_by(fn {relation, resource, _role} -> {relation, inspect(resource)} end)
      |> Enum.map(fn {relation, resource, role} ->
        row([code(relation), code(inspect(resource)), role])
      end)

    [
      "## Legacy relations and what they feed\n\n",
      "| Legacy relation | Feeds resource | As |\n|---|---|---|\n",
      rows,
      "\n"
    ]
  end

  defp summary(resources) do
    rows =
      Enum.map(resources, fn resource ->
        lenses = attribute_rows(resource)

        row([
          code(inspect(resource)),
          code(Info.strangler_phase!(resource)),
          code(Info.writes(resource) || "n/a"),
          resource |> relations() |> Enum.map_join(", ", &code(elem(&1, 0))),
          names(for %{read_only?: true} = r <- lenses, do: r.attribute),
          names(for %{kind: :unmapped} = r <- lenses, do: r.attribute)
        ])
      end)

    [
      "## Resources\n\n",
      "| Resource | Phase | Writes | Reads from | Read only | Unmapped |\n|---|---|---|---|---|---|\n",
      rows,
      "\n"
    ]
  end

  # --- one resource ------------------------------------------------------

  defp resource_section(resource, heading) do
    rows = attribute_rows(resource)

    [
      "#{heading} #{inspect(resource)}\n\n",
      facts(resource),
      "\n",
      attribute_table(rows),
      read_only_list(rows),
      unread_columns(resource),
      "\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp facts(resource) do
    phase = Info.strangler_phase!(resource)
    position = Enum.find_index(@phases, &(&1 == phase)) + 1

    [
      "- **Phase:** #{code(phase)} (#{position} of #{length(@phases)}: #{Enum.map_join(@phases, " > ", &to_string/1)})\n",
      "- **Writes reach the base table:** #{code(Info.writes(resource) || "n/a")}\n",
      view_fact(resource),
      "- **Reads from:** #{resource |> relations() |> Enum.map_join("; ", &relation_fact/1)}\n",
      join_facts(resource),
      extension_fact(resource)
    ]
  end

  defp relation_fact({relation, role}), do: "#{code(relation)} (#{role})"

  defp view_fact(resource) do
    case view_name(resource) do
      nil -> []
      view -> "- **View:** #{code(view)}\n"
    end
  end

  defp join_facts(resource) do
    resource
    |> Info.joins()
    |> Enum.map(fn join ->
      "- **Join:** #{code(join.relation)} AS #{code(join.alias)}, LEFT JOIN on #{code(join.on)}\n"
    end)
  end

  defp extension_fact(resource) do
    case Info.extension_attrs(resource) do
      [] ->
        []

      attrs ->
        "- **Owned outright** (extension table, no legacy column): #{names(attrs)}\n"
    end
  end

  defp attribute_table(rows) do
    [
      "| Attribute | Legacy source | Transform | Direction | Why |\n|---|---|---|---|---|\n",
      Enum.map(rows, fn r ->
        row([code(r.attribute), r.source, r.transform, r.direction, text(r.because)])
      end)
    ]
  end

  defp read_only_list(rows) do
    case for %{read_only?: true} = r <- rows, do: r do
      [] ->
        "\nRead only: none. Every mapped attribute can be written back.\n"

      read_only ->
        [
          "\nRead only (a write to these is refused):\n\n",
          Enum.map(read_only, fn r ->
            "- #{code(r.attribute)}: #{text(r.because || "no reason given")}\n"
          end)
        ]
    end
  end

  defp unread_columns(resource) do
    retired = retired(resource)

    [
      case unread(resource) do
        [] -> []
        columns -> "\nLegacy columns no mapping reads: #{Enum.map_join(columns, ", ", &code/1)}\n"
      end,
      Enum.map(retired, fn {columns, because} ->
        "\nRetired (the old application no longer reads): #{Enum.map_join(columns, ", ", &code/1)}" <>
          if(because, do: " - #{text(because)}", else: "") <> "\n"
      end)
    ]
  end

  # --- the rows ----------------------------------------------------------

  # One row per attribute. An `unmapped [:a, :b]` is one lens but two rows, and
  # an extension attribute is not a mapping at all but is still an attribute the
  # reader will be looking for.
  defp attribute_rows(resource) do
    twin = Info.twin(resource)

    lenses = Lens.for_resource(resource) ++ Lens.extension_lenses(resource)
    Enum.flat_map(lenses, &lens_rows(&1, resource, twin))
  end

  defp lens_rows(%Lens{combinator: combinator, entry: entry} = lens, _resource, twin)
       when combinator in [:unmapped, :default] do
    Enum.map(entry.attributes, fn attribute ->
      transform =
        case combinator do
          :unmapped -> code("NULL")
          :default -> code(default_sql(lens, attribute))
        end

      %{
        attribute: attribute,
        kind: :unmapped,
        source: "none",
        transform: transform,
        direction: "none",
        read_only?: false,
        because: entry.because || "no reason given",
        twin: twin
      }
    end)
  end

  defp lens_rows(%Lens{} = lens, resource, twin) do
    [
      %{
        attribute: lens.attribute,
        kind: lens.combinator,
        source: source_text(lens, twin),
        transform: transform_text(lens, resource, twin),
        direction: direction(lens),
        read_only?: read_only?(lens),
        because: lens.because,
        twin: twin
      }
    ]
  end

  defp read_only?(%Lens{combinator: c}) when c in [:key, :constant, :extension], do: false
  defp read_only?(%Lens{type: :masked}), do: true
  defp read_only?(%Lens{invertible: :no}), do: true
  defp read_only?(_lens), do: false

  defp direction(%Lens{combinator: :key}), do: "derived key"
  defp direction(%Lens{combinator: :constant}), do: "none (constant)"
  defp direction(%Lens{combinator: :extension}), do: "own table"
  defp direction(%Lens{type: :masked, opaque?: true}), do: "read only (opaque SQL)"
  defp direction(%Lens{type: :masked}), do: "read only"
  defp direction(%Lens{invertible: :yes}), do: "both ways"
  defp direction(%Lens{invertible: :semi}), do: "both ways, modulo a declared value"
  defp direction(%Lens{}), do: "read only"

  defp source_text(%Lens{sources: []}, _twin), do: "none"

  defp source_text(%Lens{sources: sources}, twin) do
    sources
    |> Enum.uniq()
    |> Enum.map_join(", ", &code(qualified_column(twin, &1)))
  end

  defp qualified_column(twin, {path, attribute}) do
    case Twin.resource_at(twin, path) do
      {:ok, resource} -> "#{Twin.relation(resource)}.#{Twin.column!(resource, attribute)}"
      {:error, _} -> "#{Twin.relation(twin)}.#{attribute}"
    end
  rescue
    _ -> to_string(attribute)
  end

  defp transform_text(%Lens{combinator: :rename}, _resource, _twin), do: "1:1"
  defp transform_text(%Lens{combinator: :extension}, _resource, _twin), do: "extension table"

  defp transform_text(%Lens{combinator: :key, entry: entry}, _resource, twin) do
    case entry.strategy do
      :identity ->
        "legacy key as is"

      {:uuid_v5, _} ->
        prefix = AshStrangler.KeyDerivation.name_prefix(Twin.relation(twin))
        code("uuid_v5(namespace, '#{prefix}' || legacy key)")

      {:uuid_v8, _registry, kind} ->
        "#{code("uuid_v8")} packed key (#{code(kind)})"

      other ->
        code(inspect(other))
    end
  end

  defp transform_text(%Lens{combinator: :tenant, entry: entry} = lens, _resource, twin),
    do: sql_or_name(lens, twin, entry.derive)

  defp transform_text(%Lens{forward: nil, combinator: combinator}, _resource, _twin),
    do: to_string(combinator)

  defp transform_text(%Lens{combinator: combinator} = lens, _resource, twin) do
    "#{combinator}: " <> sql_or_name(lens, twin, lens.forward)
  end

  defp sql_or_name(lens, twin, expression) do
    expression
    |> Printer.to_sql(ref: ref_frame(twin))
    |> shorten()
    |> code()
  rescue
    _ -> to_string(lens.combinator)
  end

  # Bare column for the primary relation, `alias.column` for a joined one. The
  # table above names the relation in full; the expression stays readable.
  defp ref_frame(twin) do
    fn
      {[], attribute} -> column(twin, [], attribute)
      {path, attribute} -> "#{List.last(path)}.#{column(twin, path, attribute)}"
    end
  end

  defp column(twin, path, attribute) do
    case Twin.resource_at(twin, path) do
      {:ok, resource} -> Twin.column!(resource, attribute)
      {:error, _} -> to_string(attribute)
    end
  rescue
    _ -> to_string(attribute)
  end

  defp default_sql(%Lens{forward: defaults}, attribute) when is_map(defaults),
    do: "default " <> Printer.literal(Map.get(defaults, attribute))

  defp default_sql(_lens, _attribute), do: "column default"

  defp shorten(sql) do
    sql = sql |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(sql) > @sql_limit,
      do: String.slice(sql, 0, @sql_limit - 3) <> "...",
      else: sql
  end

  # --- relations, unread and retired columns -----------------------------

  defp relations(resource) do
    twin = Info.twin(resource)
    primary = Twin.relation(twin)

    joined =
      resource |> Info.joins() |> Enum.map(&{&1.relation, "LEFT JOIN as #{&1.alias}, read only"})

    [{primary, "primary"} | joined]
  end

  defp view_name(resource) do
    if Code.ensure_loaded?(AshPostgres.DataLayer.Info) do
      case AshPostgres.DataLayer.Info.table(resource) do
        nil -> nil
        table -> "#{AshPostgres.DataLayer.Info.schema(resource) || "public"}.#{table}"
      end
    end
  end

  defp retired(resource) do
    case Info.source(resource) do
      nil -> []
      source -> Enum.map(source.retirements, &{&1.columns, &1.because})
    end
  end

  # Twin columns on the primary relation that no mapping reads and that are not
  # declared retired. The ones worth asking about: either nothing needs them, or
  # a mapping is missing.
  defp unread(resource) do
    twin = Info.twin(resource)

    read =
      resource
      |> Lens.for_resource()
      |> Enum.flat_map(& &1.sources)
      |> Enum.filter(fn {path, _} -> path == [] end)
      |> MapSet.new(&elem(&1, 1))

    retired = resource |> Info.retired() |> MapSet.new()

    twin
    |> Twin.columns()
    |> Enum.reject(&(MapSet.member?(read, &1) or MapSet.member?(retired, &1)))
    |> Enum.map(&Twin.column!(twin, &1))
  end

  # --- markdown helpers ---------------------------------------------------

  defp names([]), do: "none"
  defp names(list), do: Enum.map_join(list, ", ", &code/1)

  defp row(cells), do: ["| ", Enum.join(cells, " | "), " |\n"]

  # A code span cannot contain a backtick, and a table cell cannot contain a
  # bare pipe -- which SQL's `||` is made of. `\\|` survives inside a span in a
  # table (GFM strips the backslash before the span is parsed).
  defp code(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("`", "'")
      |> String.replace(~r/\s+/, " ")
      |> String.replace("|", "\\|")

    "`#{escaped}`"
  end

  defp text(nil), do: ""

  defp text(value) do
    value
    |> to_string()
    |> Lineage.summarize(200)
    |> String.replace("|", "\\|")
    |> String.replace("<", "&lt;")
  end
end
