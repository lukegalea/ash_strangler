# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UnionConcurrencyTest do
  @moduledoc """
  What the union's triggers do under concurrent writers, each on its own
  committed connection (the sandbox would serialise them into one).
  """

  # Committed rows in the shared fixture schema, on real connections.
  use ExUnit.Case, async: false

  @flip_to_dual_write AshStrangler.Test.Clinic.source(
                        "AshStrangler.UnionConcurrencyTest.DualWrite",
                        :dual_write,
                        :dual_write
                      )
  @flip_to_read AshStrangler.Test.Clinic.source(
                  "AshStrangler.UnionConcurrencyTest.ReadFromLegacy",
                  :read_from_legacy,
                  :dual_write
                )

  setup_all do
    # The phase variants, compiled once. Only their trigger functions are applied:
    # a flip between these two phases changes nothing else.
    functions =
      for source <- [@flip_to_dual_write, @flip_to_read] do
        [{module, _}] = Code.compile_string(source)

        for %{name: name, up: up} <- AshStrangler.Migration.statements(module),
            String.ends_with?("#{name}", "_function"),
            do: up
      end

    %{to_dual_write: Enum.at(functions, 0), to_read: Enum.at(functions, 1)}
  end

  setup %{to_read: to_read} do
    config = AshStrangler.TestRepo.config()
    opts = Keyword.take(config, [:hostname, :port, :username, :password, :database])

    clean = fn conn ->
      for table <- ~w(north_visits south_visits visits_owned) do
        Postgrex.query!(conn, "DELETE FROM clinic_union.#{table}", [])
      end

      for up <- to_read, do: Postgrex.query!(conn, up, [])
    end

    {:ok, admin} = Postgrex.start_link(opts)
    clean.(admin)

    # The test process (and its linked connections) is gone by on_exit.
    on_exit(fn ->
      {:ok, conn} = Postgrex.start_link(opts)
      clean.(conn)
    end)

    connect = fn ->
      {:ok, conn} = Postgrex.start_link(opts)
      conn
    end

    %{connect: connect, admin: admin}
  end

  defp q!(conn, sql, params \\ []), do: Postgrex.query!(conn, sql, params).rows

  test "concurrent owned inserts each get their own key and both persist", %{connect: connect} do
    conns = for _ <- 1..4, do: connect.()

    results =
      conns
      |> Enum.map(fn conn ->
        Task.async(fn ->
          for n <- 1..25 do
            [[id]] =
              q!(conn, "INSERT INTO clinic_union.visits (patient) VALUES ($1) RETURNING id", [
                "p#{n}"
              ])

            id
          end
        end)
      end)
      |> Task.await_many(30_000)

    ids = List.flatten(results)
    assert length(ids) == 100
    assert length(Enum.uniq(ids)) == 100

    assert [[100]] =
             q!(hd(conns), "SELECT count(*) FROM clinic_union.visits WHERE __branch = 'native'")
  end

  test "two inserts of the same supplied key conflict on the owned table's key", %{
    connect: connect
  } do
    [a, b] = [connect.(), connect.()]
    id = Ecto.UUID.bingenerate()

    q!(a, "BEGIN")
    q!(a, "INSERT INTO clinic_union.visits (id, patient) VALUES ($1, 'first')", [id])

    second =
      Task.async(fn ->
        Postgrex.query(b, "INSERT INTO clinic_union.visits (id, patient) VALUES ($1, 'second')", [
          id
        ])
      end)

    # The second insert waits on the first's uncommitted key.
    refute Task.yield(second, 300)
    q!(a, "COMMIT")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} = Task.await(second)
    assert [["first"]] = q!(a, "SELECT patient FROM clinic_union.visits WHERE id = $1", [id])
  end

  test "an owned insert in flight is unaffected by a phase change committing under it", ctx do
    %{connect: connect, admin: admin, to_dual_write: to_dual_write} = ctx
    [writer, flipper] = [connect.(), connect.()]

    q!(writer, "BEGIN")

    [[id]] =
      q!(writer, "INSERT INTO clinic_union.visits (patient) VALUES ('native one') RETURNING id")

    for up <- to_dual_write, do: q!(flipper, up)

    q!(writer, "COMMIT")

    assert [["native one", "native"]] =
             q!(admin, "SELECT patient, __branch FROM clinic_union.visits WHERE id = $1", [id])
  end

  test "a legacy write fires under the phase committed when its trigger runs", ctx do
    %{connect: connect, admin: admin, to_dual_write: to_dual_write, to_read: to_read} = ctx
    q!(admin, "INSERT INTO clinic_union.north_visits VALUES (1, 'ada', NULL)")
    [writer, flipper] = [connect.(), connect.()]

    update = "UPDATE clinic_union.visits SET patient = 'ada l.' WHERE __branch = 'north'"

    # Before the flip commits: refused with the declared reason.
    assert_raise Postgrex.Error, ~r/the north system writes these rows/, fn ->
      q!(writer, update)
    end

    # A transaction opened BEFORE the flip commits still sees the new phase when its trigger fires.
    q!(writer, "BEGIN")
    for up <- to_dual_write, do: q!(flipper, up)
    q!(writer, update)
    q!(writer, "COMMIT")
    assert [["ada l."]] = q!(admin, "SELECT patient_name FROM clinic_union.north_visits")

    # A write that already fired under :dual_write completes when the flip back commits under it.
    q!(writer, "BEGIN")
    q!(writer, "UPDATE clinic_union.visits SET patient = 'ada m.' WHERE __branch = 'north'")
    for up <- to_read, do: q!(flipper, up)
    q!(writer, "COMMIT")
    assert [["ada m."]] = q!(admin, "SELECT patient_name FROM clinic_union.north_visits")

    # And the next one is refused again.
    assert_raise Postgrex.Error, ~r/the north system writes these rows/, fn ->
      q!(writer, update)
    end
  end
end
