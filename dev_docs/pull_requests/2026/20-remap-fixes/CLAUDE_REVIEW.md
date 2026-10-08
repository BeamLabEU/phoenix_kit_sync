# Claude review of PR #20: Fix uuid and integer FK remaps and overwrite/merge in Pull with remap

**Reviewer**: Claude (read-only pass over the PR's own diff and the current
state of the code it touches; the DB-backed tests were not run, there is no
database in the review environment).

Checked and holding: under `overwrite`/`merge` with a present PK `match_existing_record` returns `:import` (upsert) and `skip`/`append` return `:skip_matched`; `placeholder/6` reuses the key's own binds and every identifier is a validated column name; `target` has a single construction site; no transaction wraps the import, so a swallowed `unique_violation` does not poison later rows.

## 1. IMPROVEMENT - MEDIUM: `connection_notifier/prepare.ex` `@decimal_regex`

The regex needs a dot, so a whole-number decimal was never parsed. Both exporters send `Decimal.to_string/1`, so an integral value in an unconstrained `numeric` column arrives as `"5"` and one with an exponent as `"1.5E+3"`. A string bound to `numeric` reaches Postgrex unparsed and the row fails. The float path (new in this PR) accepts `"3"` and `"1e5"`; the decimal path did not.

**Resolution:** Fixed. In a column known to be numeric, any numeric string (`\A-?\d+(\.\d+)?([eE][-+]?\d+)?\z`) becomes a `Decimal`. The type-less `value/1` keeps the dot-required rule, so a plain `"5"` elsewhere stays a string. Tests in `prepare_test.exs`.

## 2. NITPICK: `connection_notifier/prepare.ex`

The comment block documenting `@decimal_regex` sat above `parse_numeric_string/2` and `@float_regex`, away from `parse_decimal_string`.

**Resolution:** Fixed while editing the same lines.

