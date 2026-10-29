# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyExtension do
  @moduledoc """
  What may be declared `extension [...]`, and where the extension table may
  exist at all.

  Four rules, in the order this verifier checks them:

    * at most one `extension` block per source. The extension table is keyed by
      the canonical key and named after the view — a second block is a second
      claim on the same table, which is the same bug as two sources.
    * every listed attribute must exist on the resource and be otherwise
      unaccounted for. An extension attribute is its own accounting category:
      it is not mapped (there is no legacy column on the other side), not
      `constant` (it holds per-row values), not `unmapped` (it is not a NULL
      standing in for storage), and not the key.
    * a function default is refused. The view would have to call the function —
      `&Ash.UUID.generate/0`, `&DateTime.utc_now/0` — and a view that calls a
      generator returns a different value on every read. A static literal
      default is fine: it reads back through `COALESCE`, which is how a legacy
      row with no extension row at all gets the declared default.
    * no extension table in `:read_from_new` or `:decommissioned`. Past
      cutover this resource owns a real table; an extension table beside it is
      a second storage location for data that now has one authoritative home.
      Fold the columns into the owned table before the phase change.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    with %AshStrangler.Source{} = source <- AshStrangler.Info.source(dsl),
         :ok <- at_most_one(dsl, source),
         :ok <- verify_attributes(dsl, source),
         :ok <- verify_defaults(dsl, source),
         :ok <- verify_phase(dsl) do
      :ok
    else
      nil -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp at_most_one(dsl, source) do
    case source.extensions do
      [_one] ->
        :ok

      [] ->
        :ok

      many ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl, :module),
           path: [:strangler, :source, :extension],
           message: """
           #{length(many)} `extension` blocks on one source.

           The extension table is keyed by the canonical key and named after
           this resource's view -- a second block is a second claim on the same
           table, and whichever one the generator saw last would win. List all
           the attributes in one block:

               extension [:negotiating_notes, :governing_law]
           """
         )}
    end
  end

  defp verify_attributes(dsl, source) do
    declared = Enum.flat_map(source.extensions, & &1.attributes)
    resource = Verifier.get_persisted(dsl, :module)

    # Accounted for by something OTHER than the extension itself -- the overlap
    # this check exists to catch. Computed from the mappings and keys directly:
    # `Info.accounted_for/1` already includes extension attributes, so
    # subtracting the declaration would erase the very collision being tested.
    other =
      Enum.flat_map(source.mappings, fn
        %{attribute: attribute} -> [attribute]
        %AshStrangler.Unmapped{attributes: attributes} -> attributes
        _ -> []
      end) ++ Enum.map(source.keys, & &1.attribute)

    real_attributes =
      resource
      |> Ash.Resource.Info.attributes()
      |> MapSet.new(& &1.name)

    declared
    |> Enum.map(fn attribute ->
      cond do
        attribute in other ->
          {:error, attribute,
           "is already accounted for by a mapping, constant, `unmapped` or the key -- an extension attribute has no legacy side to account for"}

        not MapSet.member?(real_attributes, attribute) ->
          {:error, attribute, "is not an attribute of this resource"}

        true ->
          :ok
      end
    end)
    |> Enum.find(:ok, &match?({:error, _, _}, &1))
    |> case do
      :ok ->
        :ok

      {:error, attribute, why} ->
        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:strangler, :source, :extension],
           message: """
           extension attribute #{inspect(attribute)} #{why}.

           An extension attribute must exist on the resource and be listed
           nowhere else:

               attribute #{inspect(attribute)}, :string
               extension [#{inspect(attribute)}]
           """
         )}
    end
  end

  defp verify_defaults(dsl, source) do
    declared = Enum.flat_map(source.extensions, & &1.attributes)
    resource = Verifier.get_persisted(dsl, :module)

    by_name = Map.new(Ash.Resource.Info.attributes(resource) || [], &{&1.name, &1})

    declared
    |> Enum.map(fn attribute ->
      case Map.get(by_name, attribute) do
        %{default: default} when is_function(default) ->
          {:error, attribute}

        _ ->
          :ok
      end
    end)
    |> Enum.find(:ok, &match?({:error, _}, &1))
    |> case do
      :ok ->
        :ok

      {:error, attribute} ->
        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:strangler, :source, :extension],
           message: """
           extension #{inspect(attribute)} declares a function default.

           The view reads the column through `COALESCE`, and a function default
           would put the call in the view definition -- one evaluation per read,
           a different value every time. Give the attribute a static literal
           default:

               attribute #{inspect(attribute)}, :string, default: ""

           or none at all, and let the write path supply the value.
           """
         )}
    end
  end

  defp verify_phase(dsl) do
    phase = AshStrangler.Info.strangler_phase!(dsl)

    if AshStrangler.Info.extension_attrs(dsl) != [] and phase in [:read_from_new, :decommissioned] do
      {:error,
       Spark.Error.DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:strangler, :source, :extension],
         message: """
         `extension` is meaningless in phase #{inspect(phase)}.

         phase :read_from_new owns a real table -- fold extension columns into
         it before cutover. Past that point the resource's storage is
         authoritative and singular: an extension table beside it would be a
         second storage location for data one table already holds.
         """
       )}
    else
      :ok
    end
  end
end
