# Cursor rules — quick usage (homelab-k3s)

Shrek-style AI code review for this repo’s k3s YAML + Bash stack.

## Before review

1. **Check diff size** (≤ 150 LOC insertions+deletions vs default branch):

   ```sh
   ./scripts/check-diff-size.sh
   ```

2. **In Composer / Chat** — tag the diff, the review rule, and one-sentence PR intent:

   - `@git diff main..HEAD` (or `master..HEAD` if that is the default)
   - `@code-review.mdc`
   - One sentence: what cluster/app behavior this PR changes

Example:

> `@git diff main..HEAD` `@code-review.mdc` Intent: add NetworkPolicy for caster Postgres so only app pods reach 5432.

## Notes

- Clean → `APPROVED` + 1–2 bullets; else issue bullets only.
- Rule: `.cursor/rules/code-review.mdc`
- Prefer small PRs; oversized diffs fail step 1 until split.
