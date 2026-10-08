# PR #20: Fix uuid and integer FK remaps and overwrite/merge in Pull with remap

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `fa7a03d` (merge commit)
**Date**: 2026-10-08

## Summary

- Remap keys are canonical strings (`remap_key/1`), so a sender's wrapped or raw uuid and its text form meet; integer keys do too.
- FKs are remapped once, before matching, which stops chained remaps (42 -> 7 -> 3) and lets a unique set that contains an FK match.
- A unique-column match under `overwrite`/`merge` writes the sender's values onto the local row by the local key; `skip`/`append` leave it alone. `merge` keeps the local value where the sender's is NULL.
- A unique violation under `overwrite`/`merge` counts as skipped; numeric strings in `double precision`/`real` columns become floats; logs no longer carry key values.

## Related

All PRs #18 to #27 were merged the same day; see the sibling folders under
`dev_docs/pull_requests/2026/`.
