# Claude review of PR #21: Apply the precise transfer's ID filter on the sender

**Reviewer**: Claude (read-only pass over the PR's own diff and the current
state of the code it touches; the DB-backed tests were not run, there is no
database in the review environment).

Checked and holding: authorization order is token, active connection, `check_table_allowed`, then the filter, so a leaked token gains nothing; the key name goes through `quote_ident`, every value is a bind, the array casts are fixed; limits on ids and bytes apply on both ends.

## 1. BUG - MEDIUM: `connections_live.ex` `parse_id/1`

`Integer.parse(id)` returning `{int, ""}` also accepts `"007"`, `"+5"` and `"-0"`. The form cannot know the key type, so a text key typed as `00123` was sent as the integer 123 and the sender matched `"123"` instead, importing a different row or none.

**Resolution:** Fixed. An id is converted only when `Integer.to_string(int) == id`; otherwise it stays a string (an integer key then refuses it as an invalid filter, which beats reading another row). `parse_id/1` is `@doc false` public for `parse_id_test.exs`.

## 2. IMPROVEMENT - MEDIUM: `connection_notifier.ex` `handle_table_http_result/1`

The record preview ignored the sender's 400 `error_code`, so a range filter on a uuid key or an ID filter on a composite key showed "Unexpected response from remote site" while the pull path already mapped the same codes.

**Resolution:** Fixed. A 400 with a known filter `error_code` maps to the matching atom; anything else stays `:unexpected_response`.

## 3. NITPICK: `connection_notifier.ex` status-400 `handle_pull_response`

Any 400 from a filtered pull, `missing_fields` included, is reported as `:invalid_filter`.

**Resolution:** Not changed. Documented as intended for senders that predate `error_code`.

## 4. NITPICK: `connection_notifier.ex` `pull_table_data_with_remap/4`

Documented as "same as `pull_table_data`" but it silently ignores `:ids` and `:id_range`. The only caller never passes a filter.

**Resolution:** Not changed. If a filtered remap pull is wanted, return `{:error, :invalid_filter}` instead of ignoring the option.

## 5. NITPICK: record preview

`table-records` never sends `"filtered"`, so a pre-#21 sender ignores the filter and the preview shows its first 10 rows as if they matched. Only the import path is protected.

**Resolution:** Not changed. Preview only; nothing is written.

