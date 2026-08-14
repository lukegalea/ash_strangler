defmodule AshStrangler.Test.Generators do
  @moduledoc """
  StreamData generators for legacy rows, biased hard toward the values that
  break projections silently.

  Uniformly random strings find almost nothing here: the bugs in a
  legacy→modern projection live in case folding, Unicode normalization, NULL
  handling and timezone interpretation, and random ASCII hits none of them. So
  the interesting values are enumerated as fixed alternatives and mixed in
  deliberately, rather than left to chance.

  Every hazard below was verified by running it against PostgreSQL 17.10, not
  taken from documentation.

  ## What is deliberately excluded

  **The NUL byte.** PostgreSQL's `text` type rejects embedded NULs outright
  (SQLSTATE `54000`, "null character not permitted"). That is a limitation of
  the column type, not of any projection, so generating one would fail the
  *insert* and report a view bug that does not exist. `:alphanumeric` strings
  cannot produce it; the fixed alternatives below do not contain it.
  """

  import StreamData

  @doc """
  Wraps a generator so it produces `nil` sometimes.

  Weighted 1:4 rather than evenly. NULL is the important case, but a corpus
  that is half NULL spends most of its shrinking budget on rows that exercise
  nothing else.
  """
  def nilable(generator, nil_weight \\ 1, value_weight \\ 4) do
    frequency([{nil_weight, constant(nil)}, {value_weight, generator}])
  end

  @doc """
  Text values chosen to break the things that break quietly.

  The fixed alternatives, and what each is for:

    * **ASCII case pairs** — `citext` folds these, so they collide under an
      identity. This is the case everybody tests.
    * **Leading/trailing whitespace** — `citext` does *not* fold these. Verified:
      `' a'` and `'a'` are distinct under both `citext` and `=`. Legacy data with
      padding therefore keeps duplicates that look identical in a UI.
    * **Non-ASCII case pairs** (Turkish `İ`, German `ß`, Greek final sigma `ς`) —
      `citext` folds via SQL `lower()`, which under this cluster's `C` collation
      touches **only ASCII**. Verified: `lower('İ') = 'İ'`, unchanged. So a
      developer who believes `citext` means "case-insensitive" is right for
      ASCII and wrong for everything else, and an ASCII-only test proves the
      wrong thing.
    * **NFC vs NFD** — `café` as U+00E9 versus `e` + combining acute renders
      identically and is **unequal under `=`, under `citext`, and therefore under
      any Ash identity built on the column**. Only `normalize(x, NFC)` unifies
      them. The sneakiest entry in this list: a human reviewing the data would
      call the two rows duplicates.
    * **Astral plane, ZWJ sequences, RTL marks** — multi-byte and multi-codepoint
      values where `length()` counts codepoints, not visible characters. The
      family emoji is 7 codepoints and 25 bytes.
  """
  def adversarial_text do
    one_of([
      string(:alphanumeric, min_length: 0, max_length: 20),
      member_of(["Alice@Example.COM", "alice@example.com", "ALICE@EXAMPLE.COM"]),
      member_of([" leading", "trailing ", "\ttab", "newline\n", "  both  "]),
      member_of(["İstanbul", "istanbul", "Straße", "STRASSE", "ςόφος", "σόφος"]),
      # Written as escapes deliberately. These are the SAME visual string in
      # NFC and NFD form, so spelling them literally would give two source
      # lines that look identical, with no way for a reader to tell which is
      # which. Verified: they are unequal under `=`, under `citext`, and so
      # under any Ash identity built on the column -- only `normalize/2`
      # unifies them, which nothing in this projection calls.
      member_of([
        # NFC: a single codepoint, U+00E9.
        "caf\u00E9",
        # NFD: "e" followed by U+0301 combining acute.
        "cafe\u0301",
        # Two stacked combining marks, which normalize to neither.
        "e\u0301\u0301"
      ]),
      # Also escaped, but for a second reason: Elixir rejects raw
      # bidirectional formatting characters in source (the trojan-source
      # defence), so U+202E/U+202C cannot be written literally at all.
      member_of([
        "\u{1F600}",
        "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}",
        "\u{1F1FA}\u{1F1F8}",
        "\u0645\u0631\u062D\u0628\u0627",
        "\u202Etext\u202C"
      ]),
      constant("")
    ])
  end

  @doc """
  Naive timestamps, biased toward the two instants that are not a bijection
  with wall-clock time.

  `2024-03-10 02:30` does not exist in `America/New_York` (spring forward) and
  `2024-11-03 01:30` happens twice (fall back). Verified: PostgreSQL resolves
  both **silently** rather than raising, so there is no error path a test could
  catch — the only symptom is a wrong instant.
  """
  def adversarial_naive_datetime do
    one_of([
      map(integer(0..1_000_000_000), &NaiveDateTime.add(~N[2000-01-01 00:00:00], &1, :second)),
      member_of([~N[2024-03-10 02:30:00], ~N[2024-11-03 01:30:00]])
    ])
  end

  @doc """
  A legacy `users` row, as a map of column name to value.

  `login` is excluded: it carries a `NOT NULL` unique index, so the caller
  supplies a distinct value rather than having the generator collide with
  itself and fail on a constraint that is not what is under test.
  """
  def legacy_user_row do
    fixed_map(%{
      email: nilable(adversarial_text()),
      first_name: nilable(adversarial_text()),
      last_name: nilable(adversarial_text()),
      deleted_at: nilable(adversarial_naive_datetime())
    })
  end
end
