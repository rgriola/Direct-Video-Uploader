Last updated: May 12, 2026 - 1:25pm - GitHub Copilot (GPT-5.3-Codex)

## Summary

Describe what changed and why.

## Validation

- [ ] Server tests pass (`cd server && npm run test`)
- [ ] Admin build passes (`cd admin && npm run build`)
- [ ] Relevant manual QA completed

## Prisma / Database Checklist

- [ ] If `server/prisma/schema.prisma` changed, I added a new migration folder in `server/prisma/migrations/`
- [ ] I ran migration status check (`cd server && npm run db:status`)
- [ ] I did not use `prisma db push` in production/deploy workflow
- [ ] I documented any one-time migration ops needed by deployers (if applicable)

## Risks

List rollout risks, data risks, and rollback notes.
