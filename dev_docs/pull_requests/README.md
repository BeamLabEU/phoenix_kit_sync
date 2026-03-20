# Pull Request Documentation

This directory contains documentation for significant pull requests merged into PhoenixKitSync. It serves as an archive of design decisions, review feedback, and implementation context that lives within the repository.

## Purpose

- **Preserve institutional knowledge** beyond GitHub/GitLab PR comments
- **Survive platform migrations** - documentation stays with the code
- **Searchable history** - find past decisions using standard git tools
- **Review feedback archive** - capture important clarifications and corrections

## Directory Structure

```
dev_docs/pull_requests/
├── README.md                 # This file
├── TEMPLATE.md               # Starting point for new PR docs
├── 2026/                     # Year
│   ├── 1-sync-module-extraction/
│   │   ├── README.md         # PR summary (what, why, how)
│   │   └── CLAUDE_REVIEW.md  # Claude's review feedback
│   └── ...
```

### Naming Convention

Directory names follow the pattern: `{pr_number}-{short-slug}/`

- **PR number**: Maintains chronological order
- **Short slug**: 3-5 words describing the change (kebab-case)
- **Examples**: `1-sync-module-extraction`, `5-sql-injection-fixes`

## When to Document a PR

**Create documentation for:**
- Architecture or design changes
- Non-obvious implementation choices
- Breaking changes or migrations
- Complex features requiring multiple review rounds
- Significant review feedback revealing intent
- Features with known limitations or future work

**Skip documentation for:**
- Bug fixes with obvious solutions
- Documentation-only changes
- Simple dependency updates
- Copy/text changes

## File Types

| File | Purpose |
|------|---------|
| `README.md` | **Required.** PR summary: goal, changes, implementation details |
| `{AGENT}_REVIEW.md` | Review feedback, clarifications, issues found (see naming below) |
| `FOLLOW_UP.md` | Post-merge issues, discovered bugs, refactor notes |
| `CONTEXT.md` | Deep dive: alternatives considered, trade-offs |

### Review File Naming Convention

Review files are prefixed with the **agent name** to identify the reviewer:

| File | Agent |
|------|-------|
| `CLAUDE_REVIEW.md` | Claude (Anthropic) |
| `KIMI_REVIEW.md` | Kimi (Moonshot AI) |
| `MISTRAL_REVIEW.md` | Mistral |
| `GEMINI_REVIEW.md` | Gemini (Google) |
| `GPT_REVIEW.md` | ChatGPT / GPT (OpenAI) |

**Pattern:** `{AGENT_NAME}_REVIEW.md` — uppercase, underscores for multi-word names.

Multiple agents can review the same PR, each with their own file.

## Template

See `TEMPLATE.md` for a starting point when documenting new PRs.

## Cross-References

Link between related PRs:

```markdown
## Related PRs

- Previous: [#1](/dev_docs/pull_requests/2026/1-sync-module-extraction)
- Follow-up: [#2](/dev_docs/pull_requests/2026/2-sql-injection-fixes)
```

## Maintenance

- Keep README.md focused and scannable
- Review files (`*_REVIEW.md`) should explain *why*, not just *what*
- Update FOLLOW_UP.md if issues are discovered later
- Remove obsolete PR docs when the feature is fully deprecated
