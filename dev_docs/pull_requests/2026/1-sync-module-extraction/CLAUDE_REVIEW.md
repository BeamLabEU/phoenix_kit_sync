# Claude's Review of PR #1 — Sync Module Extraction

**Verdict: Post-merge review — critical issues require follow-up PRs**

This is a substantial extraction of 16K+ lines of peer-to-peer sync functionality from PhoenixKit into a standalone package. The domain logic is thoughtful (FK remapping, conflict strategies, session management), but several security vulnerabilities and architectural issues need attention.

---

## Critical Issues

### 1. SQL Injection in `data_importer.ex`

**File:** `lib/phoenix_kit_sync/data_importer.ex:159-187, 239-243`

```elixir
query = "SELECT * FROM #{table} WHERE #{where_clause} LIMIT 1"
```

Raw string interpolation for table and column names without validation or quoting. Unlike `schema_inspector.ex` which properly uses `valid_identifier?/1` and `quote_identifier/1`, the importer does neither. An attacker crafting table/column names in sync payloads could inject arbitrary SQL.

**Impact:** Remote code execution via SQL injection during data import.

**Fix:** Apply `valid_identifier?/1` validation and `quote_identifier/1` to all dynamic identifiers in the importer, matching the pattern already used in `schema_inspector.ex`.

### 2. Timing-unsafe token comparison in `connection.ex`

**File:** `lib/phoenix_kit_sync/connection.ex:359-376`

```elixir
hash_token(token) == hash  # direct comparison — vulnerable to timing attacks
```

Direct `==` comparison of token hashes leaks information about the expected hash through response timing differences.

**Fix:** Use `Plug.Crypto.secure_compare/2` or `:crypto.hash_equals/2`.

### 3. Timing-unsafe password comparison in `api_controller.ex`

**File:** `lib/phoenix_kit_sync/web/api_controller.ex`

```elixir
if provided_password == config.incoming_password
```

Same timing attack vector as the token comparison.

**Fix:** Use `Plug.Crypto.secure_compare/2`.

---

## Security Concerns

### 4. No rate limiting on API endpoints (HIGH)

**File:** `lib/phoenix_kit_sync/web/api_controller.ex`

All API endpoints (`register_connection`, `delete_connection`, `list_tables`, `pull_data`) can be called without rate limits. An attacker with a valid or brute-forced token can exfiltrate data rapidly or hammer the endpoint to brute-force tokens.

### 5. No SSRF validation on `site_url` (HIGH)

**Files:** `lib/phoenix_kit_sync/connection.ex`, `lib/phoenix_kit_sync/connection_notifier.ex`

`site_url` is used to make outbound HTTP requests to remote sites. No validation against internal/private IP ranges — an attacker could point `site_url` at `http://169.254.169.254` (cloud metadata) or internal services.

**Fix:** Validate URL scheme (https only in production) and block RFC 1918 / link-local addresses.

### 6. PID conversion from untrusted input (MEDIUM)

**File:** `lib/phoenix_kit_sync/web/sender.ex:630-638`

```elixir
defp string_to_pid(pid_string) when is_binary(pid_string) do
  :erlang.list_to_pid(~c"<#{pid_part}>")
end
```

Converts untrusted string input to BEAM PIDs. While rescued on failure, repeated malformed inputs could be used for DoS.

### 7. Auth token as sole protection (MEDIUM)

**File:** `lib/phoenix_kit_sync/web/api_controller.ex`

Cross-site API calls rely only on bearer token authentication. No request signing (HMAC), no nonce/replay protection. A leaked token grants full data access until rotated.

---

## Architecture Issues

### 8. God modules — files far too large

| Module | Lines | Recommendation |
|--------|-------|----------------|
| `connections_live.ex` | 2,829 | Split into Index, Form, Sync + components |
| `receiver.ex` | 2,045 | Extract state machine, split UI from business logic |
| `connection_notifier.ex` | 1,637 | Split into RemoteClient, DataTransformer, RecordImporter |
| `api_controller.ex` | 1,294 | Split by resource or extract service modules |

`connections_live.ex` alone has 30+ `handle_event` callbacks. Phoenix recommends keeping LiveViews under ~15 callbacks.

### 9. N+1 query patterns

- `schema_inspector.ex` runs `get_exact_count()` per table in `list_tables/0` — 50 tables = 50 queries. Should batch via `pg_stat_user_tables`.
- `data_importer.ex` runs `find_existing()` per record during import — 500 records = 500 SELECT queries. Should batch lookups.

### 10. LiveView mount anti-pattern

**File:** `lib/phoenix_kit_sync/web/history.ex:19-38`

`load_transfers()` runs unconditionally in `mount/3` without a `connected?` check, causing the database query to execute twice (dead render + connected render).

### 11. FK remapping limitations

**File:** `lib/phoenix_kit_sync/connection_notifier.ex:1286-1480`

- No cycle detection for circular FK references — could fail silently
- Schema inspection runs per import instead of being cached per sync session
- Assumes string PKs — integer PKs may break the remap mapping

---

## Code Quality

### Issues

- **Inconsistent error formats:** Mix of `:error`, `{:error, reason}`, and `{:error, reason, details}` across modules
- **Overly broad rescues:** `connection_notifier.ex` catches `rescue e ->` hiding root causes
- **Hardcoded values:** `"/phoenix_kit"` prefix, `@base "/admin/sync"`, various timeouts — should be configurable
- **Missing `@spec`:** Many public functions lack typespecs
- **No telemetry:** No `:telemetry` events for observability on sync operations
- **No audit logging:** Data access operations aren't logged (who synced what, when)
- **Inconsistent API error format:** Different JSON shapes across endpoints

### Positives

- Good module docstrings on most files
- Proper `with` chains for error handling pipelines
- `connected?` check correctly used in `connections_live.ex` mount
- ETS SessionStore with process monitoring — well-justified GenServer usage
- Smart table exclusions (oban_*, schema_migrations, tokens)
- FK remapping with UUID detection shows real thought for cross-tenant sync
- Clean separation between `Connection` schema and `Connections` context
- Proper cleanup in WebSocket `terminate` callbacks

---

## Recommended Priority

| Priority | Issue | Action |
|----------|-------|--------|
| **Immediate** | SQL injection in `data_importer.ex` | Apply `valid_identifier?/1` + `quote_identifier/1` |
| **Immediate** | Timing-unsafe comparisons | Switch to `Plug.Crypto.secure_compare/2` |
| **Soon** | Rate limiting | Add rate limiting to API endpoints |
| **Soon** | SSRF protection | Validate `site_url` against private IP ranges |
| **Next iteration** | God modules | Split the 4 largest modules |
| **Next iteration** | N+1 queries | Batch lookups in importer and schema inspector |
| **Backlog** | Telemetry + audit logging | Add `:telemetry` events and data access logs |
| **Backlog** | Standardize errors | Consistent `{:error, reason}` and JSON error format |
