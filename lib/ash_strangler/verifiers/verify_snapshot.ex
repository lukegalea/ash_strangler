# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifySnapshot do
  @moduledoc """
  V-SNAPSHOT: a twin pinned to a snapshot catalog agrees with it.

  For a twin declaring `twin do snapshot "…/catalog.json" end`, compilation
  fails, naming each offending column, when:

    * the catalog has no such relation;
    * the twin declares a column the catalog does not have;
    * a column's type is not the one `AshStrangler.Snapshot.Types` gives it,
      including the `one_of` value set of an enum or `CHECK ... IN` column;
    * a column's nullability differs (`allow_nil?` against `NOT NULL`);
    * the catalog has a column the twin leaves out, and it is neither a declared
      secret nor a type with no Ash equivalent;
    * the primary key differs;
    * a declared secret is not a column of the relation.

  The type rule is the generator's own (`AshStrangler.Snapshot.Types`), so a
  twin written by `mix ash_strangler.gen.twin --from-snapshot` passes by
  construction and a hand edit that drifts from the catalog does not.

  ## What it proves, and what it does not

  It proves twin and catalog agree, with no database, at compile time. It does
  not prove the catalog agrees with the legacy database: that is
  `mix ash_strangler.snapshot drift`. The catalog is an `@external_resource`
  of the twin (`AshStrangler.Transformers.DeclareSnapshotResource`), so a new
  capture recompiles every twin pinned to it.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Snapshot.Types
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case AshStrangler.Twin.snapshot(dsl) do
      nil -> :ok
      path -> verify_against(dsl, path)
    end
  end

  defp verify_against(dsl, path) do
    relation_name =
      "#{AshPostgres.DataLayer.Info.schema(dsl) || "public"}.#{AshPostgres.DataLayer.Info.table(dsl)}"

    with {:ok, catalog} <- AshStrangler.Snapshot.read_catalog(path),
         {:ok, relation} <- fetch_relation(catalog, relation_name, path) do
      case problems(dsl, relation, catalog) do
        [] -> :ok
        problems -> {:error, error(dsl, problems_message(dsl, relation_name, path, problems))}
      end
    else
      {:error, message} -> {:error, error(dsl, message)}
    end
  end

  defp fetch_relation(catalog, name, path) do
    case catalog["relations"] do
      %{^name => relation} -> {:ok, relation}
      _ -> {:error, "the snapshot catalog #{path} has no relation `#{name}`."}
    end
  end

  defp problems(dsl, relation, catalog) do
    secrets = AshStrangler.Twin.secrets(dsl)
    columns = Map.new(relation["columns"], &{&1["name"], &1})
    attributes = Ash.Resource.Info.attributes(dsl)
    declared = MapSet.new(attributes, &column_name/1)

    Enum.flat_map(
      attributes,
      &attribute_problems(&1, columns[column_name(&1)], relation, catalog)
    ) ++
      missing_problems(relation, catalog, declared, secrets) ++
      secret_problems(secrets, columns) ++
      primary_key_problems(dsl, relation)
  end

  defp attribute_problems(attribute, nil, _relation, _catalog) do
    ["`#{column_name(attribute)}`: the twin declares it; the catalog has no such column"]
  end

  defp attribute_problems(attribute, column, relation, catalog) do
    name = column["name"]

    type_problems =
      case Types.for_column(column, relation, catalog) do
        {:omit, _note} ->
          [
            "`#{name}`: `#{column["type"]}` has no Ash type, but the twin declares it as #{inspect(attribute.type)}"
          ]

        {:ok, %{type: type, one_of: one_of}} ->
          type_problem(name, attribute, type) ++ one_of_problem(name, attribute, one_of)
      end

    nullability =
      if attribute.allow_nil? == column["not_null"] do
        expected =
          if column["not_null"],
            do: "NOT NULL (allow_nil? false)",
            else: "nullable (allow_nil? true)"

        [
          "`#{name}`: the catalog says #{expected}; the twin says allow_nil? #{attribute.allow_nil?}"
        ]
      else
        []
      end

    type_problems ++ nullability
  end

  defp type_problem(name, attribute, type) do
    if Ash.Type.get_type(type) == attribute.type do
      []
    else
      [
        "`#{name}`: the catalog's type gives #{inspect(type)}; the twin declares #{inspect(attribute.type)}"
      ]
    end
  end

  defp one_of_problem(_name, _attribute, nil), do: []

  defp one_of_problem(name, attribute, one_of) do
    declared = attribute.constraints |> Keyword.get(:one_of, []) |> Enum.map(&to_string/1)

    if MapSet.new(declared) == MapSet.new(one_of) do
      []
    else
      [
        "`#{name}`: the catalog's value set is #{inspect(one_of)}; the twin's one_of is #{inspect(declared)}"
      ]
    end
  end

  defp missing_problems(relation, catalog, declared, secrets) do
    for column <- relation["columns"],
        name = column["name"],
        not MapSet.member?(declared, name),
        name not in secrets,
        match?({:ok, _typed}, Types.for_column(column, relation, catalog)) do
      "`#{name}`: the catalog has it (#{column["type"]}); the twin does not declare it and it is not a secret"
    end
  end

  defp secret_problems(secrets, columns) do
    for secret <- secrets, not Map.has_key?(columns, secret) do
      "`#{secret}`: declared secret, but the catalog has no such column"
    end
  end

  defp primary_key_problems(dsl, relation) do
    twin_key =
      dsl
      |> Ash.Resource.Info.primary_key()
      |> Enum.map(&column_name(Ash.Resource.Info.attribute(dsl, &1)))

    catalog_key = (relation["primary_key"] || %{})["columns"] || []

    if twin_key == catalog_key do
      []
    else
      ["primary key: the catalog has #{inspect(catalog_key)}; the twin has #{inspect(twin_key)}"]
    end
  end

  defp column_name(attribute), do: to_string(attribute.source || attribute.name)

  defp problems_message(dsl, relation_name, path, problems) do
    regenerate =
      "mix ash_strangler.gen.twin --from-snapshot #{path} --relation #{relation_name} " <>
        "--module #{inspect(Verifier.get_persisted(dsl, :module))} " <>
        "--domain #{inspect(Verifier.get_persisted(dsl, :domain))} " <>
        "--repo #{inspect(AshPostgres.DataLayer.Info.repo(dsl, :read))}"

    """
    The twin for `#{relation_name}` disagrees with the snapshot catalog #{path}:

    #{Enum.map_join(problems, "\n", &"  * #{&1}")}

    The catalog is the pinned legacy schema. If it is right, regenerate the twin:

        #{regenerate}

    If the legacy schema really changed, capture a new snapshot first
    (`mix ash_strangler.snapshot capture`).
    """
  end

  defp error(dsl, message) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:twin, :snapshot],
      message: message
    )
  end
end
