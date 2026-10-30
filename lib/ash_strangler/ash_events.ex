# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.AshEvents do
  @moduledoc """
  The AshEvents boundary for shared-row resources.

  Two rules, one per direction of the events/observations distinction:

    * **Replay is refused on shared-row resources in a write phase.** AshEvents
      replay clears and rebuilds the resource's data from its event log — for
      a resource over shared rows that means deleting or rewriting LIVE LEGACY
      rows. `refuse_replay!/1` is the documented host hook: call it at the top
      of the replay path and it raises, naming the resource and the phase,
      before AshEvents touches anything. Past cutover (`:read_from_new`) the
      resource owns its table and the host may replay — the guard refuses
      only the phases where the rows are shared.

    * **Observations are never recorded as action events.** The events bridge
      (`mix ash_strangler.gen.events_bridge`) renders a companion READ-ONLY
      resource over `strangler_observations` that the host mounts beside its
      event log for a unified timeline. It has no create/update/destroy, so
      observations are not replayable as actions and "Luke ran
      `Contract.archive`" (an action event) stays distinct from "the shared
      row's `archived` changed in legacy" (an observation).

  The optional `:ash_events` dependency is not imported here: the guard reads
  only the resource's own DSL, and the bridge reads only the store. The
  dependency exists for the host's event log side and the bridge fixture.
  """

  alias AshStrangler.Info

  @doc """
  Raises when AshEvents replay would clear or rebuild live legacy rows.

  Wired at the top of the host's replay path:

      def replay_my_events do
        AshStrangler.AshEvents.refuse_replay!(MyApp.Clm.Contract)
        AshEvents.Replay.replay(...)  # host's own replay
      end
  """
  def refuse_replay!(resource) do
    phase = Info.strangler_phase!(resource)

    if phase in [:read_from_legacy, :dual_write] do
      raise ArgumentError,
            """
            ash_strangler: AshEvents replay refused on shared-row resource \
            #{inspect(resource)} (phase #{inspect(phase)}): replay would clear \
            or rebuild live legacy rows.

            The resource's `table` is a compatibility VIEW over \
            #{Info.relation(resource)} -- rows the legacy application owns and \
            writes. AshEvents replay deletes and re-creates the resource's \
            records; through the INSTEAD OF triggers every one of those is a \
            legacy write.

            Replay this resource's events only after the phase is \
            `:read_from_new` and the compatibility layer is gone.
            """
    end

    :ok
  end
end
