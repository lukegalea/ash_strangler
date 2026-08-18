# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

spark_locals_without_parens = [
  add: 1,
  affine: 1,
  affine: 2,
  as: 1,
  backfill_interlock?: 1,
  because: 1,
  coalesce: 1,
  coalesce: 2,
  collapse: 1,
  collapse: 2,
  concat: 1,
  concat: 2,
  constant: 2,
  constant: 3,
  decode: 1,
  decode: 2,
  default: 1,
  from: 1,
  hit_policy: 1,
  key: 1,
  key: 2,
  map: 1,
  map: 2,
  multiply: 1,
  negate: 1,
  negate: 2,
  notify?: 1,
  notify_channel: 1,
  on_update: 1,
  phase: 1,
  read_only?: 1,
  separator: 1,
  set: 1,
  source: 1,
  source: 2,
  state: 1,
  state: 2,
  strategy: 1,
  unmapped: 1,
  unmapped: 2,
  values: 1,
  when: 1,
  writes: 1,
  zone: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  import_deps: [:ash, :ash_postgres, :ash_state_machine, :spark],
  plugins: [Spark.Formatter],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
