# PR #25: Fix skipped rows and early ends in paged transfers

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `54549b6` (merge commit)
**Date**: 2026-10-08

## Summary

- `Client.transfer` and the Receiver LiveView advance the offset by the number of records received, not the requested batch size, so a sender cap below the batch size no longer skips rows.
- Both read until an empty page instead of trusting the sender's `has_more`, which costs one extra request per table.
- The Receiver uses its own pending offset rather than the sender's echo; `DataExporter.max_limit/0` is exposed and the `batch_size` docs say a sender returns at most 1000 per request.

Stacked on #22 and merged with it (see #22 for the conflict resolutions; the only extra one is `receiver.ex`, where this PR no longer uses `Params`, so that alias is dropped).

## Related

All PRs #18 to #27 were merged the same day; see the sibling folders under
`dev_docs/pull_requests/2026/`.
