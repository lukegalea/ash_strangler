# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyArchival do
  @moduledoc """
  `AshArchival`'s archive attribute must have a legacy representation.

  AshArchival sets `archived_at` on destroy. On a strangled resource that
  write goes through the compatibility layer -- and if the archive attribute
  has no mapping, extension membership or tenant-style derivation, the view
  has no column for it and AshArchival's set fails at the first archive.

  The Contract fixture is the positive case: `archived_at` is mapped (`map +
  zone`) and its legacy encoding is the collapse's `archived` state. The
  negative case names the fix: map the archive attribute onto the legacy
  encoding, put it in the extension store, or refuse archival on this
  resource.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if Code.ensure_loaded?(AshArchival) and archival?(dsl) do
      verify_archive_attribute(dsl)
    else
      :ok
    end
  end

  # Archival is configured iff AshArchival.Resource is on the resource (the
  # docs' usage: `extensions: [AshArchival.Resource]`; AshArchival itself is
  # not an extension module). The section option carries a default, so the
  # persisted archive attribute alone is not the signal.
  defp archival?(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    module != nil and AshArchival.Resource in Spark.extensions(module)
  rescue
    _ -> false
  end

  defp verify_archive_attribute(dsl) do
    archive_attribute = archive_attribute_name(dsl)
    resource = Verifier.get_persisted(dsl, :module)

    cond do
      is_nil(archive_attribute) ->
        :ok

      writable_mapping?(dsl, archive_attribute) ->
        :ok

      true ->
        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:strangler, :source],
           message: """
           archival has no legacy representation: map the archive attribute \
           onto the legacy encoding or refuse archival on this resource.

           AshArchival sets #{inspect(archive_attribute)} on destroy; on a \
           shared-row resource that set goes through the compatibility view, \
           and the view has no column for an attribute nothing accounts for.

           The Contract fixture is the positive shape:

               map :archived_at, from: :archived, zone: "UTC"

           -- with the lifecycle collapse owning the legacy encoding. The \
           extension store does not count: AshArchival's set would land in \
           the extension row while the legacy lifecycle stays silent -- two \
           answers to "was this archived?".
           """
         )}
    end
  end

  defp archive_attribute_name(dsl) do
    # The setup transformer guarantees the attribute exists once archival is
    # on the resource; the bang variant reads the persisted attribute name.
    AshArchival.Resource.Info.archive_attribute!(dsl)
  rescue
    _ -> nil
  end

  # Writable mapping = a lens whose reverse exists (map, zone, cast, collapse
  # -- anything with a write direction). The extension store does NOT count:
  # AshArchival's set would go to the extension row while the LIFECYCLE the
  # legacy encoding expresses stays silent -- two answers to "was this
  # archived?".
  defp writable_mapping?(dsl, attribute) do
    dsl
    |> AshStrangler.Lens.for_resource()
    |> Enum.find(&(&1.attribute == attribute))
    |> case do
      %{writes: writes} when writes != [] -> true
      _ -> false
    end
  end
end
