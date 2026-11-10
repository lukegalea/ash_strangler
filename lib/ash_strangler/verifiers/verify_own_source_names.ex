# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyOwnSourceNames do
  @moduledoc """
  A strangled resource's own attributes are refused a `source:` while a view stands
  in for its table.

  ## Why

  The generated view names every column after the attribute: `... AS title`. Ash
  reads and writes that view by the attribute's `source:` when it has one --
  `SELECT i0."heading_col" ...` -- so the first query fails at runtime with
  `column i0.heading_col does not exist`, long after the module compiled. Measured,
  not assumed: `test/ash_strangler/own_source_names_runtime_test.exs` creates the view for
  such a resource and reads it.

  The view's column names are the resource's contract with Ash, and the mapping
  already says how a legacy column becomes an attribute. Two places that could each
  rename the column would be two facts about one name, and they would have to agree
  by hand.

  ## What it covers

  Every attribute the view emits: the key, the extension attributes, the tenant, the
  mapped ones and the `unmapped` ones. An attribute whose `source:` is its own name
  is not a rename and is accepted.

  ## What it does not cover

    * **The twin.** The twin is the legacy relation, and `source:` is how it spells a
      column Elixir would not want as an atom (`"Type"`, `effectiveDate`). Every
      statement that names a legacy column reads it through `AshStrangler.Twin.column!/2`.
    * **`:read_from_new` and `:decommissioned`.** From the cutover the resource owns a
      real table, and `source:` is how it names that table's columns. The reverse view
      spells them that way (`AshStrangler.Sql.ReverseView`).

  ## What to do instead

  Rename the attribute to the name the view should carry, or put the legacy name on
  the twin attribute, which does support `source:`, and map the resource attribute
  `from:` it.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Info
  alias Spark.Dsl.Verifier

  @owned_table_phases [:read_from_new, :decommissioned]

  @impl true
  def verify(dsl) do
    with true <- Info.strangled?(dsl),
         phase when phase not in @owned_table_phases <- Info.strangler_phase!(dsl),
         [_ | _] = renamed <- renamed_attributes(dsl) do
      {:error, error(dsl, phase, renamed)}
    else
      _ -> :ok
    end
  end

  defp renamed_attributes(dsl) do
    dsl
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(fn attribute ->
      not is_nil(attribute.source) and to_string(attribute.source) != to_string(attribute.name)
    end)
  end

  defp error(dsl, phase, renamed) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:attributes, hd(renamed).name],
      message: """
      #{plural(renamed)} of #{inspect(Verifier.get_persisted(dsl, :module))} #{verb(renamed)} a `source:`, which the strangler view cannot honour:

      #{Enum.map_join(renamed, "\n", &describe/1)}

      In phase #{inspect(phase)} this resource reads and writes a view, and the view names every
      column after its attribute (`... AS #{hd(renamed).name}`). Ash would ask for the column
      by `source:` instead, so the first query fails at runtime with
      `column ... does not exist`.

      Either:

        * drop the `source:` and, if the name is wrong, rename the attribute; or
        * put the legacy column's name on the twin attribute, which does support
          `source:`, and map this attribute `from:` it:

              map #{inspect(hd(renamed).name)}, from: :twin_attribute_name

      From `:read_from_new` the resource owns a table and `source:` names that table's
      columns again; it is only refused while a view stands in for the table.
      """
    )
  end

  defp describe(attribute) do
    "  * #{inspect(attribute.name)} has `source: #{inspect(attribute.source)}`"
  end

  defp plural([_]), do: "An attribute"
  defp plural(_many), do: "Attributes"

  defp verb([_]), do: "carries"
  defp verb(_many), do: "carry"
end
