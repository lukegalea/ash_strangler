# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Estate do
  @moduledoc """
  The whole legacy schema, accounted for: one disposition for every relation
  and every column of a snapshot catalog (`AshStrangler.Snapshot`).

  A resource's verifiers look one way, from the new model to the legacy one:
  every attribute of a strangled resource is answered. Nothing there asks the
  opposite question, which legacy columns no mapping reads. An estate asks it,
  for the whole catalog at once:

      defmodule MyApp.Legacy.Estate do
        use AshStrangler.Estate

        estate do
          snapshot "priv/legacy/snapshot/catalog.json"
          resources [MyApp.Lending.Book, MyApp.Lending.Loan, MyApp.Legacy.Members]
          plugins [MyApp.Legacy.EstateRules]

          carried "lending.books.shelf_note", because: "free text the new model does not read"
          deferred "lending.fines", wave: :billing, target: "Lending.Fine", because: "its own wave"
          legacy_only "lending.sessions", because: "the old application's own sessions"
          dead "lending.fax_log", because: "no writer since the fax machine went"
          residue "lending.old_reservations", because: "old restores still carry it"
          open_reference "lending.loans.loans_member_id_fkey", because: "NOT VALID; cleaned in wave 2"
        end
      end

  ## Dispositions

  **Computed**, never written by hand:

    * `mapped`: a mapping of one of `resources` reads the column, as a mapped
      value, the key, the tenant derivation or a join.
    * `secret`: a twin involved declares it in `secrets`.
    * any kind a plug-in claims (`AshStrangler.Estate.Plugin`).

  **Declared** in the `estate` block, each with `because:`:

    * `carried`: kept opaquely beside the mapped row so the legacy application
      loses nothing at cutover (columns only);
    * `deferred`: a later `wave` strangles it into `target`;
    * `legacy_only`: stays with the legacy application;
    * `dead`: nothing reads or writes it.

  `deferred`, `legacy_only` and `dead` may name a whole relation, which
  covers every column it has, including ones a later capture adds.

  ## Checks

  `evaluate/1` returns an `AshStrangler.Estate.Report` whose `problems` are:

    * **declarations**: every declaration names a relation or column the
      catalog has; `carried` names a column; nothing is declared twice; no
      column is declared inside a relation declared as a whole; a `residue` is
      not in the catalog; an `open_reference` names a foreign key it has.
    * **resources**: each of `resources` is a strangled resource or a twin,
      and every column a mapping reads is in the catalog.
    * **claims**: plug-in claims name catalog columns and unreserved kinds.
    * **coverage**: every column has exactly one disposition: computed claims,
      or one declaration, never both and never neither. A column added to the
      catalog without a disposition fails here.
    * **consistency**: a relation declared as a whole has no computed claims.
    * **writers**: no two resources write one legacy column.
    * **references**: a foreign key whose columns are mapped is validated and
      references columns that are themselves mapped or claimed, or it is an
      `open_reference`. An `open_reference` that is not needed is stale.
    * **plugin**: whatever each plug-in's `check/1` returns.

  `AshStrangler.Verifiers.VerifyEstate` runs the declaration checks at compile
  time, against the catalog alone. The rest read other modules' compiled
  mappings, so they run in the `:ash_strangler_estate` Mix compiler
  (`Mix.Tasks.Compile.AshStranglerEstate`), after every module is compiled, and
  in `mix ash_strangler.estate`, which also exports the JSON manifest
  (`manifest/1`).
  """

  use Spark.Dsl, default_extensions: [extensions: [AshStrangler.Estate.Dsl]]

  alias AshStrangler.Estate.{Disposition, OpenReference, Report, Residue}

  @doc "The catalog path the estate covers."
  @spec snapshot(module() | Spark.Dsl.t()) :: String.t()
  def snapshot(estate), do: Spark.Dsl.Extension.get_opt(estate, [:estate], :snapshot, nil)

  @doc "The resources and twins the estate computes claims from."
  @spec resources(module() | Spark.Dsl.t()) :: [module()]
  def resources(estate), do: Spark.Dsl.Extension.get_opt(estate, [:estate], :resources, [])

  @doc "The plug-ins, in declaration order."
  @spec plugins(module() | Spark.Dsl.t()) :: [module()]
  def plugins(estate), do: Spark.Dsl.Extension.get_opt(estate, [:estate], :plugins, [])

  @doc "The declared dispositions, in declaration order."
  @spec dispositions(module() | Spark.Dsl.t()) :: [Disposition.t()]
  def dispositions(estate), do: entities(estate, Disposition)

  @doc "The declared residue relations."
  @spec residue(module() | Spark.Dsl.t()) :: [Residue.t()]
  def residue(estate), do: entities(estate, Residue)

  @doc "The declared open references."
  @spec open_references(module() | Spark.Dsl.t()) :: [OpenReference.t()]
  def open_references(estate), do: entities(estate, OpenReference)

  @doc """
  Evaluates the estate: claims, coverage, every check and every plug-in.

  Reads the catalog and the compiled resources; touches no database.
  """
  @spec evaluate(module()) :: Report.t()
  def evaluate(estate), do: Report.build(estate)

  @doc """
  The estate manifest (format `ash_strangler.estate/1`): every relation and
  column with its disposition, the residue, the open references, the drift
  allow patterns, counts and problems. Encode it with
  `AshStrangler.Snapshot.Catalog.encode/1` for canonical bytes.
  """
  @spec manifest(Report.t()) :: map()
  def manifest(%Report{} = report), do: Report.manifest(report)

  @doc """
  Allow patterns for `AshStrangler.Snapshot.drift/3`: one
  `"relation schema.table"` per `residue`, which is the difference drift
  reports for a relation the catalog does not have.
  """
  @spec drift_allow(module()) :: [String.t()]
  def drift_allow(estate), do: Enum.map(residue(estate), &"relation #{&1.relation}")

  defp entities(estate, struct) do
    estate
    |> Spark.Dsl.Extension.get_entities([:estate])
    |> Enum.filter(&is_struct(&1, struct))
  end
end
