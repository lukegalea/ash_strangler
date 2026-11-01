# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Twin.Generator do
  @moduledoc """
  Writes a twin's source from a catalog relation.

  `mix ash_strangler.gen.twin` places the file and wires the domain; this
  decides what the file says. It reads only an `AshStrangler.Snapshot.Catalog`
  map, whether that came from `catalog.json` (`--from-snapshot`) or from
  introspecting a live database, so both modes write the same twin for the same
  schema, and `AshStrangler.Verifiers.VerifySnapshot` passes on what it writes.

  ## What comes from where

    * columns, in declaration order, typed by `AshStrangler.Snapshot.Types`;
    * the primary key;
    * an `identity` per non-partial unique constraint or index whose columns are
      all declared (a partial index makes a column unique among some rows,
      which is not what an identity claims);
    * a `belongs_to` per single-column foreign key whose target is a twin that
      exists or is generated in the same run. A composite foreign key has no
      `belongs_to` shape, and an approximation would join on a weaker condition
      than the constraint.

  Secret columns are left out, with a comment saying so.
  """

  alias AshStrangler.Snapshot.Types

  @typedoc """
  What to generate:

    * `:relation` — `"schema.table"`, a key of the catalog's `"relations"`;
    * `:catalog` — the catalog;
    * `:module`, `:domain`, `:repo` — modules;
    * `:destination` — `fn "schema.table" -> module | nil end`, resolving
      foreign key targets;
    * `:secrets` — column names to omit;
    * `:snapshot` — the catalog path to pin the twin to, or `nil`;
    * `:watch` — a channel, or `nil`;
    * `:system_actor` — the system-actor policy check, as source text, or
      `nil` (optional);
    * `:command` — the provenance line for the moduledoc.
  """
  @type spec :: %{
          optional(:system_actor) => String.t() | nil,
          relation: String.t(),
          catalog: map(),
          module: module(),
          domain: module(),
          repo: module(),
          destination: (String.t() -> module() | nil),
          secrets: [String.t()],
          snapshot: String.t() | nil,
          watch: String.t() | nil,
          command: String.t()
        }

  @doc "The twin's source, formatted as the generator writes it."
  @spec render(spec()) :: String.t()
  def render(spec) do
    relation = Map.fetch!(spec.catalog["relations"], spec.relation)
    {schema, table} = split(spec.relation)
    columns = columns(relation, spec)

    """
    defmodule #{inspect(spec.module)} do
      #{moduledoc(spec)}

      use Ash.Resource,
        domain: #{inspect(spec.domain)},
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStrangler.Twin]#{authorizers(spec)}

      postgres do
        table #{inspect(table)}
        schema #{inspect(schema)}
        repo #{inspect(spec.repo)}
        # Ash does not own this table and never will.
        migrate? false
      end
    #{twin_block(spec)}
      attributes do
    #{indent(Enum.map_join(columns, "\n\n", &attribute/1), 4)}
      end
    #{identities_block(identities(relation, columns))}#{relationships_block(relationships(relation, columns, spec))}
      actions do
        defaults [:read]
      end
    end
    """
  end

  # --- columns -----------------------------------------------------------

  defp columns(relation, spec) do
    primary_key = (relation["primary_key"] || %{})["columns"] || []

    Enum.map(relation["columns"], fn column ->
      name = column["name"]

      base = %{
        column: name,
        name: attribute_name(name),
        allow_nil?: not column["not_null"],
        primary_key?: name in primary_key,
        type: nil,
        one_of: nil,
        note: nil
      }

      cond do
        name in spec.secrets ->
          %{
            base
            | note: "`#{name}` is declared secret (`twin do secrets ... end`) and is not carried."
          }

        is_nil(base.name) ->
          %{base | note: unnameable_note(name)}

        true ->
          case Types.for_column(column, relation, spec.catalog) do
            {:ok, typed} -> Map.merge(base, typed)
            {:omit, note} -> %{base | note: note}
          end
      end
    end)
  end

  defp unnameable_note(column) do
    """
    `#{column}` has no name Elixir will accept as an attribute, so it is not
    declared here. Ash's `source:` carries a column whose name merely differs from
    its attribute's -- it cannot supply a name where none can be formed.
    """
  end

  # A column name Elixir would not want as an atom keeps its real name in Ash's
  # `source:`, which is what `AshStrangler.Twin.column!/2` reads.
  defp attribute_name(column) do
    underscored = Macro.underscore(column)

    if underscored =~ ~r/^[a-z][a-z0-9_]*$/, do: String.to_atom(underscored), else: nil
  end

  # --- identities and relationships --------------------------------------

  # The primary key is skipped: it is `primary_key? true` already, and
  # `AshStrangler.Twin.unique_column_sets/1` folds it in.
  defp identities(relation, columns) do
    declared = declared(columns)
    primary_key = (relation["primary_key"] || %{})["columns"]

    for %{"name" => name, "columns" => keys, "predicate" => nil} <- relation["unique"],
        keys != primary_key,
        Enum.all?(keys, &Map.has_key?(declared, &1)) do
      %{name: String.to_atom(name), keys: Enum.map(keys, &declared[&1])}
    end
  end

  defp relationships(relation, columns, spec) do
    declared = declared(columns)

    for %{
          "columns" => [source],
          "references" => %{"relation" => target, "columns" => [destination]}
        } <-
          relation["foreign_keys"],
        Map.has_key?(declared, source),
        module = spec.destination.(target),
        destination_name = attribute_name(destination) do
      %{
        name: relationship_name(declared[source], target),
        destination: module,
        source_attribute: declared[source],
        destination_attribute: destination_name
      }
    end
  end

  defp declared(columns) do
    for %{type: type, name: name, column: column} <- columns,
        type != nil,
        into: %{},
        do: {column, name}
  end

  # Named from the source attribute, not the column: `clientPartyId` and
  # `providerPartyId` are `client_party_id` and `provider_party_id` by then, so
  # two keys to one table get two names rather than both the table's.
  defp relationship_name(source_attribute, target) do
    {_schema, table} = split(target)
    source = Atom.to_string(source_attribute)

    case String.replace_suffix(source, "_id", "") do
      ^source -> attribute_name(table)
      stripped -> String.to_atom(stripped)
    end
  end

  # --- rendering ---------------------------------------------------------

  defp moduledoc(spec) do
    staleness =
      if spec.snapshot do
        "It is pinned to the snapshot catalog `#{spec.snapshot}`, so\n" <>
          "`AshStrangler.Verifiers.VerifySnapshot` fails compilation when the two disagree."
      else
        "It is a snapshot of a schema this application does not own, so it goes\n" <>
          "stale silently -- `mix ash_strangler.check` diffs it against the database."
      end

    """
    @moduledoc \"\"\"
    The twin for `#{spec.relation}` — the legacy relation, declared as an
    ordinary Ash resource so a mapping can name its columns and have them mean
    something. See `AshStrangler.Twin`.

    Generated by:

        mix ash_strangler.gen.twin#{spec.command}

    Hand edits are lost the next time that runs. #{staleness}
    \"\"\"
    """
    |> String.trim_trailing()
    |> indent(2)
    |> String.trim_leading()
  end

  defp authorizers(spec) do
    if spec[:system_actor], do: ",\n    authorizers: [Ash.Policy.Authorizer]", else: ""
  end

  defp twin_block(spec) do
    lines =
      [
        spec.snapshot && "snapshot #{inspect(spec.snapshot)}",
        spec.secrets != [] && "secrets #{inspect(Enum.map(spec.secrets, &String.to_atom/1))}",
        spec.watch && "watch #{inspect(spec.watch)}",
        spec[:system_actor] && "system_actor #{spec[:system_actor]}"
      ]
      |> Enum.filter(& &1)

    if lines == [], do: "", else: twin_block_lines(lines)
  end

  defp twin_block_lines(lines) do
    """

      twin do
    #{indent(Enum.join(lines, "\n"), 4)}
      end
    """
  end

  defp attribute(%{type: nil} = column), do: comment(column.note)

  defp attribute(column) do
    declaration = if column.one_of, do: block_attribute(column), else: inline_attribute(column)

    case column.note do
      nil -> declaration
      note -> comment(note) <> "\n" <> declaration
    end
  end

  defp inline_attribute(column) do
    "attribute #{inspect(column.name)}, #{inspect(column.type)}, " <>
      Enum.join(options(column), ", ")
  end

  # The block form only when there is a `constraints` to carry.
  defp block_attribute(column) do
    body =
      options(column)
      |> Enum.map(&String.replace(&1, ": ", " ", global: false))
      |> Kernel.++(["constraints one_of: #{inspect(Enum.map(column.one_of, &String.to_atom/1))}"])
      |> Enum.join("\n")

    """
    attribute #{inspect(column.name)}, #{inspect(column.type)} do
    #{indent(body, 2)}
    end
    """
    |> String.trim_trailing()
  end

  defp options(column) do
    [
      if(column.primary_key?, do: "primary_key?: true"),
      if(not column.allow_nil?, do: "allow_nil?: false"),
      "public?: true",
      if(to_string(column.name) != column.column,
        do: "source: #{inspect(String.to_atom(column.column))}"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp identities_block([]), do: ""

  defp identities_block(identities) do
    """

      identities do
    #{Enum.map_join(identities, "\n", &"    identity #{inspect(&1.name)}, #{inspect(&1.keys)}")}
      end
    """
  end

  defp relationships_block([]), do: ""

  defp relationships_block(relationships) do
    """

      relationships do
    #{Enum.map_join(relationships, "\n\n", &indent(relationship(&1), 4))}
      end
    """
  end

  # `define_attribute? false` because the foreign key column is already an
  # attribute; letting the relationship define it too gives two declarations of
  # one column, and Ash refuses the resource.
  defp relationship(relationship) do
    """
    belongs_to #{inspect(relationship.name)}, #{inspect(relationship.destination)} do
      source_attribute #{inspect(relationship.source_attribute)}
      destination_attribute #{inspect(relationship.destination_attribute)}
      define_attribute? false
      public? true
    end
    """
    |> String.trim_trailing()
  end

  defp comment(text) do
    text
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> "#"
      line -> "# " <> line
    end)
  end

  defp indent(text, spaces) do
    padding = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> padding <> line
    end)
  end

  defp split(relation) do
    case String.split(relation, ".", parts: 2) do
      [schema, table] -> {schema, table}
      [table] -> {"public", table}
    end
  end
end
