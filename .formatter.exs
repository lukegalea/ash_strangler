spark_locals_without_parens = [
  because: 1,
  constant: 2,
  from: 1,
  index: 1,
  index: 2,
  into: 1,
  key: 1,
  key: 2,
  map: 1,
  map: 2,
  map: 3,
  phase: 1,
  source: 1,
  source: 2,
  to: 1,
  to: 2,
  unmapped: 1,
  unmapped: 2,
  writable?: 1,
  writes: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  import_deps: [:ash, :ash_postgres, :spark],
  plugins: [Spark.Formatter],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
