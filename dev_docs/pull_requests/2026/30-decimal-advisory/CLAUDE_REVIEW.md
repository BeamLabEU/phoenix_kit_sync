# Claude review of PR #30: Update decimal to 3.1.2 for an unbounded allocation advisory

**Reviewer**: Claude (read-only pass over the PR diff and the current code it touches; the DB-backed tests were not run, there is no database in the review environment).

Lock-only change (`decimal` 3.1.1 → 3.1.2, hash and checksum updated). `mix.exs` does not pin `decimal` and `ecto` requires `~> 3.0`, so 3.1.2 satisfies every requirement. `mix.lock` is not published to Hex, so consumers resolve their own version; the advisory is closed for this repo's test and dev runs only. No finding.
