# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Twin.Generator do
  @moduledoc """
  Writes a twin's source from a catalog relation.

  `mix ash_strangler.gen.twin` places the file and wires the domain; this
  decides what the file says. What it decides about the *relation* (the columns
  and their types, the identities) is `AshStrangler.Twin.Introspection`, which
  `mix ash_strangler.check` calls too. It reads only an `AshStrangler.Snapshot.Catalog`
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

  alias AshStrangler.Twin.Introspection

  @typedoc """
  What to generate:

    * `:relation` — `"schema.table"`, a key of the catalog's `"relations"`;
    * `:schema`, `:table` — that relation's two names, kept apart because a name with a dot in
      it cannot be read back out of `:relation`;
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
          schema: String.t(),
          table: String.t(),
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
    %{schema: schema, table: table} = spec

    columns =
      relation
      |> Introspection.columns(spec.catalog, spec.secrets)
      |> Enum.map(&atomize_name/1)

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

  # --- identities and relationships --------------------------------------

  defp identities(relation, columns) do
    for %{name: name, keys: keys} <- Introspection.identities(relation, columns),
        do: %{name: String.to_atom(name), keys: keys}
  end

  # The one place a name from the catalog becomes an atom: here, at codegen, over
  # a bounded read. `AshStrangler.Twin.Introspection` hands names over as strings
  # so that `mix ash_strangler.check` never makes one.
  defp atomize_name(%{name: nil} = column), do: column
  defp atomize_name(%{name: name} = column), do: %{column | name: String.to_atom(name)}

  defp attribute_atom(column) do
    case Introspection.attribute_name(column) do
      nil -> nil
      name -> String.to_atom(name)
    end
  end

  defp relationships(relation, columns, spec) do
    declared = Introspection.declared(columns)

    for %{
          "columns" => [source],
          "references" => %{"relation" => target, "columns" => [destination]}
        } <-
          relation["foreign_keys"],
        Map.has_key?(declared, source),
        module = spec.destination.(target),
        destination_name = attribute_atom(destination) do
      %{
        name: relationship_name(declared[source], target),
        destination: module,
        source_attribute: declared[source],
        destination_attribute: destination_name
      }
    end
  end

  # Named from the source attribute, not the column: `clientPartyId` and
  # `providerPartyId` are `client_party_id` and `provider_party_id` by then, so
  # two keys to one table get two names rather than both the table's.
  defp relationship_name(source_attribute, target) do
    table = target_table(target)
    source = Atom.to_string(source_attribute)

    case String.replace_suffix(source, "_id", "") do
      ^source -> attribute_atom(table)
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

  # A foreign key's target is a name out of the catalog, which keys its relations by
  # `schema.table` and keeps no parts of its own, so the table can only be read back off it.
  # It names a relationship and nothing else, so a dot in the table name costs a less tidy
  # name, never a wrong statement.
  defp target_table(target) do
    case String.split(target, ".", parts: 2) do
      [_schema, table] -> table
      [table] -> table
    end
  end
end
