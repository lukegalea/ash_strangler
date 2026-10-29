<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Out-of-resource mappings

A mapping can live in its own module as a Spark DSL fragment. The body is still
the **same** `strangler do ... end` grammar; there is no second DSL and nothing
to sync by hand.

```elixir
defmodule MyApp.Legacy.ContractMapping do
  use AshStrangler.Mapping, resource: MyApp.Clm.Contract

  strangler do
    phase :dual_write

    source MyApp.Legacy.ClmContracts do
      key :id, from: :id, strategy: :identity
      map :name, from: :name
    end
  end
end

defmodule MyApp.Clm.Contract do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [MyApp.Legacy.ContractMapping]

  # postgres, attributes and actions; no extensions: and no strangler block.
end
```

`AshStrangler.Mapping` expands to a `Spark.Dsl.Fragment` of `Ash.Resource` and
carries `AshStrangler.Resource` with it. Spark merges the fragment sections into
the resource config **before** transformers and verifiers run, so a fragment
mapping gets the same verifiers, obligations, diagram lineage and migration
SQL as an inline mapping.

`resource:` is recorded by the fragment's `target/0` callback. Spark merges the
fragment declarations but does not persist the attached fragment-module list
on the parent, so `mix ash_strangler.check` verifies the declared target from
the source entity's Spark declaration site (file + location) and the fragment
modules compiled from that site. A mismatch reports:

> mapping X declares target Y but is attached to Z

If the site cannot be correlated unambiguously, the check reports that too;
it does not silently skip the promise.

## One source, not two

`VerifySingleSource` counts `source` entities after Spark merges fragments.
A resource can attach two fragments, or attach one and also declare an inline
source; either shape is refused. `AshStrangler.Info.source/1` intentionally
returns the first entity, so without the verifier a second mapping would be
silently ignored and the generated view would depend on declaration order.

Keep one mapping per resource: move the inline source into the fragment, or
drop the extra fragment.

## Generated DDL does not care where it was declared

`test/ash_strangler/mapping_fragment_test.exs` compares the complete
`Migration.statements/1` lists — `up` and `down` — for the same mapping inline
and in a fragment. They are byte-identical. The Contract fixture is the live
shape: the resource module has no `strangler` block; the mapping is in
`test/support/contract.ex`'s `ContractMapping` fragment.
