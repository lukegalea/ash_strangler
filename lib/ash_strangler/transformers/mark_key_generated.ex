# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Transformers.MarkKeyGenerated do
  @moduledoc """
  Marks the mapped primary key `generated? true`, because the database computes
  it.

  ## The problem this removes

  A strangler resource's primary key is derived, by the view, from the legacy
  key — which does not exist until the row is inserted. So it cannot be
  supplied on create, and it cannot have a default either. Declared the obvious
  way:

      attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false

  every `create` fails with `attribute id is required`, because Ash requires any
  `allow_nil? false` attribute that has neither a value nor a default.

  The fix is `generated? true`, which tells Ash the data layer produces the
  value and to read it back rather than demand it. That is not a workaround: it
  is accurate. The view genuinely generates the column.

  ## Why the extension does this rather than the user

  The DSL already says which attribute the key is — `key :id, from: "id", ...` —
  so requiring the author to *also* remember an unrelated-looking flag on the
  attribute is asking them to state the same fact twice, and the failure for
  forgetting is a confusing runtime error on every create rather than anything
  that points at the mapping.

  Only ever *adds* the flag. A resource that already declares `generated? true`
  is left alone, and no other property of the attribute is touched.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Must run before AshPostgres builds its own view of the resource, and before
  # Ash's own attribute verifiers settle. Running early is safe here because
  # this reads only the `strangler` section, which is fully present as soon as
  # the DSL is parsed.
  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    with true <- AshStrangler.Info.strangled?(dsl),
         %{keys: [key]} <- AshStrangler.Info.source(dsl),
         %{generated?: false} = attribute <- attribute(dsl, key.attribute) do
      # An explicit matcher: `replace_entity/3`'s default one compares
      # `__identifier__`, which `Ash.Resource.Attribute` does not have, so the
      # default raises rather than failing to match.
      {:ok,
       Transformer.replace_entity(
         dsl,
         [:attributes],
         %{attribute | generated?: true},
         &(&1.name == key.attribute)
       )}
    else
      _ -> {:ok, dsl}
    end
  end

  defp attribute(dsl, name) do
    dsl
    |> Transformer.get_entities([:attributes])
    |> Enum.find(&(&1.name == name))
  end
end
