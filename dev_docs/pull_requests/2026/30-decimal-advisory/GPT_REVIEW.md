# GPT review of PR #30

**Date:** 2026-10-13.

## IMPROVEMENT - HIGH: the advisory floor must reach Hex consumers

The PR correctly updated the local lock to Decimal 3.1.2. A published library does not impose its lock on consuming applications, so that change alone left consumers free to retain an affected version. Sync also directly calls Decimal APIs but previously declared it only through transitive dependencies.

**Fixed:** declare `{:decimal, ">= 3.1.2 and < 4.0.0"}` in `mix.exs`. `mix deps.get` retained the existing lock; there was no unrelated dependency upgrade. A conformance test rejects older releases and admits later 3.x versions.

The [maintainer's advisory](https://github.com/ericmj/decimal/security/advisories/GHSA-6c27-994x-c52f), published 2026-10-10, names 3.1.2 as the patched version for CVE-2026-97853. The described trigger is an uncontrolled number of places passed to rounding. This review does not claim a new remote rounding exploit in Sync; it ensures that the release carries the security floor the PR intended.

**Compatibility:** a host pinned to Decimal 2.x must update its dependency constraints; the package will now refuse that combination during resolution. Versions from 3.1.2 through later 3.x remain allowed.

Validation: dependency-floor test, dependency resolution without lock changes, complete prior suite (**2,156 tests, 0 failures**) and the full precommit gate including Hex audit. PostgreSQL numeric NaN/infinity round trips also pass on REST and WebSocket. No publication/version change performed.
