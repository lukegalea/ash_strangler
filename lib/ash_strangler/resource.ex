# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Resource do
  @moduledoc """
  Ash resource extension for strangler-fig migrations.

      use Ash.Resource,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStrangler.Resource]

  Adds the `strangler` section (see `AshStrangler.Dsl`), the verifiers that
  decide whether a mapping is legal, and -- for `:read_from_legacy` on
  `AshPostgres.DataLayer` -- the transformer that derives the compatibility
  view.

  ## What this version does

  Verification, plus view generation for `:read_from_legacy` only. `:dual_write`
  `INSTEAD OF` triggers, the reversed `:read_from_new` view, backfill, the
  reconciler and the listener are later steps — see the plan's §11 step table.
  The checks were shipped first and stayed useful on their own against a
  hand-written strangler migration; the generator is built against that oracle
  rather than alongside it.

  ## Diagrams

  When the optional `:ash_diagram` dependency is present this extension also
  implements `AshDiagram.Data.Extension`, so a strangled resource carries its
  legacy source into any entity-relationship diagram drawn of the application —
  including the ones `mix ash.generate_resource_diagrams` and `Clarity` produce,
  neither of which knows this package exists.

  That is the point of the hook: the legacy table is part of the data model for
  as long as the migration runs, and a diagram that omits it is describing a
  system that does not exist yet. For the mapping itself, drawn column by
  column, see `AshStrangler.Diagram.Mapping`.
  """

  use Spark.Dsl.Extension,
    sections: AshStrangler.Dsl.sections(),
    transformers: [
      AshStrangler.Transformers.MarkKeyGenerated
    ],
    verifiers: [
      AshStrangler.Verifiers.VerifyCompleteMapping,
      AshStrangler.Verifiers.VerifyNotMigrated,
      AshStrangler.Verifiers.VerifyTimestampZones,
      AshStrangler.Verifiers.VerifyJoinedMappingsReadOnly,
      AshStrangler.Verifiers.VerifyWritableMappingsReversible,
      AshStrangler.Verifiers.VerifyNoUpserts,
      AshStrangler.Verifiers.VerifyReverseMappable,
      AshStrangler.Verifiers.VerifyIdentitiesBacked,
      AshStrangler.Verifiers.VerifyPhaseTransition
    ]

  # Only when `:ash_diagram` is there to define the behaviour. Declaring it
  # unconditionally would make the extension -- which every strangled resource
  # depends on -- fail to compile without an optional dependency.
  if Code.ensure_loaded?(AshDiagram.Data.Extension) do
    @behaviour AshDiagram.Data.Extension

    alias AshDiagram.EntityRelationship.Attribute
    alias AshDiagram.EntityRelationship.Entity
    alias AshDiagram.EntityRelationship.Relationship

    @doc false
    @impl AshDiagram.Data.Extension
    def supports?(AshDiagram.Data.EntityRelationship), do: true
    def supports?(_creator), do: false

    @doc false
    @impl AshDiagram.Data.Extension
    def extend_diagram(AshDiagram.Data.EntityRelationship, diagram) do
      # `extend_diagram/2` is handed the diagram and nothing else, so the
      # resources are recovered from the entities already in it. That is not a
      # workaround -- it is what keeps the hook honest, because it can only
      # annotate resources the diagram actually drew.
      strangled = diagram.entries |> Enum.flat_map(&strangled_entity/1) |> Enum.uniq()

      %{diagram | entries: diagram.entries ++ legacy_entries(strangled)}
    end

    def extend_diagram(_creator, diagram), do: diagram

    defp strangled_entity(%Entity{id: id}) do
      module = id |> IO.iodata_to_binary() |> resolve()

      if module, do: [{id, module}], else: []
    end

    defp strangled_entity(_entry), do: []

    defp resolve(id) do
      module = Module.concat([id])

      if Code.ensure_loaded?(module) and
           function_exported?(module, :spark_dsl_config, 0) and
           AshStrangler.Info.strangled?(module),
         do: module
    rescue
      ArgumentError -> nil
    end

    defp legacy_entries(strangled) do
      entities =
        strangled
        |> Enum.group_by(fn {_id, module} -> AshStrangler.Info.source(module).relation end)
        |> Enum.map(fn {relation, members} -> legacy_entity(relation, members) end)

      relationships =
        Enum.map(strangled, fn {id, module} ->
          %Relationship{
            left: {AshStrangler.Info.source(module).relation, :exactly_one},
            right: {IO.iodata_to_binary(id), :zero_or_more},
            identifying?: false,
            label: "strangler"
          }
        end)

      entities ++ relationships
    end

    defp legacy_entity(relation, members) do
      attributes =
        members
        |> Enum.flat_map(fn {_id, module} -> legacy_columns(module) end)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&%Attribute{type: "column", name: &1})

      %Entity{id: relation, label: relation, attributes: attributes}
    end

    # Only the columns the mapping actually names. This package never reads the
    # legacy schema, so anything else would be invention.
    defp legacy_columns(module) do
      keys = Enum.map(AshStrangler.Info.source(module).keys, & &1.from)

      mapped =
        module
        |> AshStrangler.Info.mappings()
        |> Enum.flat_map(fn mapping ->
          case mapping.column do
            column when is_binary(column) -> [column]
            _ -> resolved_columns(mapping.from)
          end
        end)

      Enum.uniq(keys ++ mapped)
    end

    defp resolved_columns(from) do
      case AshStrangler.Diagram.Sql.columns(from) do
        {:ok, columns} -> columns
        :unresolved -> []
      end
    end
  end
end
