# PR #29: Paging of tables without a primary key

**Status:** Merged and reviewed before publication on 2026-10-13.

Keyless tables can move over the socket only when the entire table fits in one page. Larger tables and keyset positions are refused; REST continues to require a primary key.

Reviews: [Claude](CLAUDE_REVIEW.md), [GPT](GPT_REVIEW.md).
