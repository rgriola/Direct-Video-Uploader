# How to Review a Pull Request on GitHub

This guide walks you through the complete process of reviewing a pull request (PR) in this repository (the **Fixer** app) — from finding the PR to submitting your review decision.

---

## What is a Pull Request?

A pull request is a proposal to merge a set of code changes from one branch into another (usually `main`). Reviewing a PR means reading those changes, leaving feedback, and either approving them or asking for improvements before they are merged.

---

## Step 1 — Navigate to the Pull Request

1. Open the repository on GitHub (the repository is named `Direct-Video-Uploader` but contains the **Fixer** app):
   **https://github.com/rgriola/Direct-Video-Uploader**
2. Click the **Pull requests** tab near the top of the page.
3. Find the PR you want to review in the list and click its title to open it.

---

## Step 2 — Read the Description

The PR description is shown at the top of the conversation thread. It explains:

- **What** changed and **why**.
- Any related issues it closes (look for `Closes #123` links).
- A checklist of completed and remaining work.

Read this first — it gives you context before you look at the code.

---

## Step 3 — Review the Changed Files

1. Click the **Files changed** tab (next to "Conversation" and "Commits").
2. You'll see a **diff** — lines highlighted in **red** were removed, lines in **green** were added.
3. Scroll through each changed file and read the changes carefully.

### Tips for reading diffs

| Symbol | Meaning |
|--------|---------|
| `+` (green) | Line was added |
| `-` (red) | Line was removed |
| No symbol (white) | Unchanged context line |

Use the **viewed** checkbox on each file to track your progress.

---

## Step 4 — Leave Inline Comments

If you spot something that needs discussion or fixing:

1. Hover over a line number on the left side of the diff — a **blue `+` button** appears.
2. Click it to open a comment box on that specific line.
3. Type your comment (e.g., *"This variable name is unclear, can we rename it?"*).
4. Click **Start a review** (not "Add single comment") so all your comments are submitted together at the end.

You can also select a **range of lines** by clicking the first line number, then shift-clicking the last.

---

## Step 5 — Check the Commits

Click the **Commits** tab to see a list of individual commits in the PR. You can click any commit to see exactly what changed in that snapshot. This is useful for understanding *how* the changes evolved.

---

## Step 6 — Look at CI Status

Below the conversation thread, a **checks** section shows whether automated tests and builds passed. Look for:

- ✅ Green checkmarks — all checks passed.
- ❌ Red X marks — something failed. Click **Details** to read the logs.

Do not approve a PR that has failing checks unless you have a good reason.

---

## Step 7 — Submit Your Review

Once you have read all the changes and left your inline comments:

1. Click the green **Review changes** button at the top-right of the **Files changed** tab.
2. Write a **summary comment** describing your overall impression.
3. Choose one of three options:

| Option | When to use it |
|--------|---------------|
| **Comment** | You have observations or questions but no blocking feedback. |
| **Approve** | The changes look good and are ready to merge. |
| **Request changes** | There are issues that must be fixed before merging. |

4. Click **Submit review**.

---

## Step 8 — Merge (if you are the maintainer)

After the PR is approved and all checks pass:

1. Return to the **Conversation** tab.
2. Click the **Merge pull request** button.
3. Choose a merge strategy:
   - **Create a merge commit** — preserves all commit history.
   - **Squash and merge** — collapses all commits into one (cleaner history).
   - **Rebase and merge** — replays commits on top of the base branch.
4. Click **Confirm merge**.
5. Optionally delete the source branch using the button that appears after merging.

---

## Quick Reference Checklist

Use this when reviewing any PR in this repository:

- [ ] Read the PR description and understand the intent.
- [ ] Check which issue(s) it references or closes.
- [ ] Review all changed files in the **Files changed** tab.
- [ ] Leave inline comments on anything unclear or incorrect.
- [ ] Confirm CI checks are passing.
- [ ] Verify the changes work as described (ask for a screenshot or test steps if needed).
- [ ] Submit your review (Comment / Approve / Request changes).

---

## Common Review Etiquette

- **Be specific** — Instead of "this is wrong", say "this function will return `null` when `userId` is undefined — can we add a guard?"
- **Be kind** — Assume good intent. Phrase requests as suggestions, not commands.
- **Separate nits from blockers** — Prefix minor style issues with `nit:` so the author knows they are optional.
- **Respond promptly** — Aim to review within one business day when tagged.

---

## Getting Help

If you have questions about a PR or this guide, open an issue in the repository or ask in the team Slack channel.
