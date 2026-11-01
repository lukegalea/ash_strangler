-- SPDX-FileCopyrightText: 2026 Luke Galea
--
-- SPDX-License-Identifier: MIT

-- A lending library's legacy schema: the estate fixture.

CREATE SCHEMA IF NOT EXISTS lending;

CREATE TABLE lending.branches (
    id integer PRIMARY KEY,
    name text NOT NULL,
    fax text
);

CREATE TABLE lending.members (
    id integer PRIMARY KEY,
    email text NOT NULL,
    full_name text,
    pin_hash text,
    branch_id integer REFERENCES lending.branches (id)
);

CREATE TABLE lending.books (
    id integer PRIMARY KEY,
    title text NOT NULL,
    isbn text,
    branch_id integer NOT NULL REFERENCES lending.branches (id),
    shelf_note text
);

CREATE TABLE lending.loans (
    id integer PRIMARY KEY,
    book_id integer NOT NULL REFERENCES lending.books (id),
    member_id integer NOT NULL,
    due_on date NOT NULL,
    returned_on date
);

ALTER TABLE lending.loans
    ADD CONSTRAINT loans_member_id_fkey FOREIGN KEY (member_id) REFERENCES lending.members (id) NOT VALID;

CREATE TABLE lending.fines (
    id integer PRIMARY KEY,
    loan_id integer NOT NULL REFERENCES lending.loans (id),
    amount_cents integer NOT NULL
);

CREATE TABLE lending.sessions (
    id text PRIMARY KEY,
    member_id integer,
    data text
);

CREATE TABLE lending.fax_log (
    id integer PRIMARY KEY,
    sent_at timestamp without time zone
);
