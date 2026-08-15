# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

spark_locals_without_parens = [
  as: 1,
  because: 1,
  cast: 1,
  column: 1,
  columns: 1,
  constant: 2,
  constant: 3,
  from: 1,
  from_zone: 1,
  index: 1,
  index: 2,
  into: 1,
  join: 1,
  join: 2,
  key: 1,
  key: 2,
  map: 1,
  map: 2,
  map: 3,
  notify?: 1,
  notify_channel: 1,
  on: 1,
  phase: 1,
  source: 1,
  source: 2,
  strategy: 1,
  to: 1,
  type: 1,
  unique: 1,
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
