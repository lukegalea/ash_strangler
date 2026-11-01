-- SPDX-FileCopyrightText: 2026 Luke Galea
--
-- SPDX-License-Identifier: MIT

-- The extension preamble: pg_dump -n never emits CREATE EXTENSION, and where an
-- extension lives decides how every type in schema.sql resolves.
CREATE SCHEMA IF NOT EXISTS clinic;
CREATE EXTENSION IF NOT EXISTS citext SCHEMA clinic;
