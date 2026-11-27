#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT
#
# Judge this repository's Elixir code against the 26 Iron Laws, using the
# deterministic judge in ash_agent_tools (`mix ash_agent.laws`). Wired into
# `mix precommit` and CI. The laws and their tiers are documented in
# ash_agent_tools; the behavioural subset is applied as a review checklist.
#
# Usage: scripts/iron-laws.sh [diff|tree]
#
#   diff  Judge only the lines added since BASE: committed-but-unpushed work,
#         staged and unstaged edits, and untracked files. BASE is the merge
#         base of HEAD with $IRON_LAWS_BASE (CI sets it) or, by default, with
#         origin/main. An empty diff passes.
#   tree  Judge every tracked Elixir file under lib/ and compare the hits with the
#         reviewed baseline, scripts/iron-laws.baseline.json. A hit missing
#         from the baseline fails; so does a baseline entry that no longer
#         fires, so the baseline cannot silently outlive the code it excuses.
#
# In both modes a hit that matches a baseline entry (same law, file and
# trimmed line) passes. The judge gates at its default floor, `likely`;
# review-tier hits are counted but never fail the run.
#
# ash_agent_tools is an `only: :dev` dependency, so the judge always runs
# under MIX_ENV=dev — including when called from `mix precommit`, which runs
# under MIX_ENV=test. The judge is pure text processing: it neither boots nor
# compiles the application.

set -euo pipefail

mode="${1:-all}"
root="$(git rev-parse --show-toplevel)"
cd "$root"

baseline="scripts/iron-laws.baseline.json"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v jq >/dev/null || { echo "iron-laws: jq is required" >&2; exit 2; }

pathspec=('lib/*.ex' 'lib/*.heex')

judge() {
  MIX_ENV=dev mix ash_agent.laws "$@"
}

baseline_keys() {
  jq -c '.[] | {law, file, text}' "$baseline" | sort -u
}

run_diff() {
  local base ref="${IRON_LAWS_BASE:-origin/main}"
  if git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
    base="$(git merge-base "$ref" HEAD)"
  elif git rev-parse --verify --quiet "origin/main^{commit}" >/dev/null; then
    base="$(git merge-base origin/main HEAD)"
  else
    # No base to compare against (an unborn branch): judge the whole tree
    # instead of passing vacuously.
    run_tree
    return
  fi

  {
    git diff --no-color "$base" -- "${pathspec[@]}"
    git ls-files --others --exclude-standard -- "${pathspec[@]}" | while read -r f; do
      git diff --no-color --no-index /dev/null "$f" || true
    done
  } > "$tmp/added.diff"

  if [ ! -s "$tmp/added.diff" ]; then
    echo "iron-laws diff: no Elixir changes since ${base:0:12}, nothing to judge"
    return 0
  fi

  judge - --diff --out "$tmp/diff.json" < "$tmp/added.diff"

  awk '/^\+\+\+ /{ f = $2; sub(/^b\//, "", f) } { print NR "\t" f }' "$tmp/added.diff" \
    | jq -R -n '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' > "$tmp/linemap.json"

  jq -c --slurpfile map "$tmp/linemap.json" '
    (.sources // [.]) | .[] | .violations[]
    | {law, file: $map[0][(.line | tostring)],
       text: (.text | sub("^\\+"; "") | gsub("^\\s+|\\s+$"; "")),
       tier, hint}
  ' "$tmp/diff.json" > "$tmp/diff-hits"

  local new
  new="$(jq -c '{law, file, text}' "$tmp/diff-hits" | sort -u | comm -23 - <(baseline_keys))"

  if [ -z "$new" ]; then
    echo "iron-laws diff: clean since ${base:0:12} ($(jq -r '.counts.review' "$tmp/diff.json") review-tier notes, $(wc -l < "$tmp/diff-hits") baselined hits)"
    return 0
  fi

  echo "iron-laws diff: lines added since ${base:0:12} break an Iron Law:" >&2
  echo "$new" | while read -r key; do
    jq -r --argjson k "$key" '
      select(.law == $k.law and .file == $k.file and .text == $k.text)
      | "  #\(.law) \(.tier)  \(.file)  \(.text)\n      \(.hint)"
    ' "$tmp/diff-hits" | head -2
  done >&2
  return 1
}

run_tree() {
  local files
  mapfile -d '' files < <(git ls-files -z -- "${pathspec[@]}")

  if [ "${#files[@]}" -eq 0 ]; then
    echo "iron-laws tree: no tracked Elixir files"
    return 0
  fi

  judge --out "$tmp/tree.json" "${files[@]}"

  jq -c '
    (.sources // [.]) | .[] | .source as $src
    | .violations[] | {law, file: $src, text: (.text | gsub("^\\s+|\\s+$"; ""))}
  ' "$tmp/tree.json" | sort -u > "$tmp/found"
  baseline_keys > "$tmp/allowed"

  local new stale status=0
  new="$(comm -23 "$tmp/found" "$tmp/allowed")"
  stale="$(comm -13 "$tmp/found" "$tmp/allowed")"

  if [ -n "$new" ]; then
    echo "iron-laws tree: hits not in $baseline:" >&2
    echo "$new" | jq -r '"  #\(.law)  \(.file)  \(.text)"' >&2
    status=1
  fi

  if [ -n "$stale" ]; then
    echo "iron-laws tree: baseline entries that no longer fire -- delete them from $baseline:" >&2
    echo "$stale" | jq -r '"  " + .' >&2
    status=1
  fi

  if [ "$status" -eq 0 ]; then
    echo "iron-laws tree: $(wc -l < "$tmp/found") hits, all in the reviewed baseline"
  fi

  return "$status"
}

case "$mode" in
  diff) run_diff ;;
  tree) run_tree ;;
  all)
    status=0
    run_diff || status=1
    run_tree || status=1
    exit "$status"
    ;;
  *)
    echo "usage: scripts/iron-laws.sh [diff|tree]" >&2
    exit 2
    ;;
esac
