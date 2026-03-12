# Contributing to Fixer

Thank you for contributing! This document explains the workflow for getting changes into the repository.

---

## Branching

- Base all new work off the `main` branch.
- Use descriptive branch names, e.g. `fix/websocket-auth`, `feat/admin-dashboard`, `docs/pr-guide`.

## Making Changes

1. Create a feature branch.
2. Follow the conventions in [`.github/copilot-instructions.md`](.github/copilot-instructions.md):
   - ES Modules only (`import`/`export`).
   - Fastify plugin pattern for routes.
   - Prisma camelCase in ORM calls; PostgreSQL snake_case in raw SQL.
   - `BigInt` values must be serialized with `.toString()` before JSON responses.
3. Run the dev server locally before opening a PR:
   ```bash
   npm run dev
   ```

## Opening a Pull Request

1. Push your branch to GitHub.
2. Open a PR against `main`.
3. Fill out the **pull request template** — every section matters.
4. Link the related issue if one exists (`Closes #<number>`).

## Reviewing a Pull Request

Not sure how the review process works? Read the step-by-step guide:

👉 **[docs/PULL_REQUEST_REVIEW_GUIDE.md](docs/PULL_REQUEST_REVIEW_GUIDE.md)**

## Merging

PRs require at least one approval and all CI checks passing before merge. The author or a maintainer performs the final merge.
