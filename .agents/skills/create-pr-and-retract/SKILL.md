---
name: create-pr-and-retract
description: >
  For every code or config change in this repo, open a pull request via GitHub
  MCP only (never gh CLI, curl, or tokens). If you later learn the PR is no
  longer valid, retract it through GitHub MCP as well. Use whenever you are
  about to commit, push, or land a change, and again whenever a PR you opened
  becomes invalid.
---

# Create a PR for every change — retract when invalid

## Hard rules

1. **Always use GitHub MCP** for every GitHub platform action: create/update/close PRs, comments, branch checks, merges, and remote branch deletion. Do **not** use `gh`, REST with a token, `GITHUB_TOKEN` / `GH_TOKEN`, browser UI, or any other API client as a fallback.
2. **Never push a change straight to `main` / `master` / the default branch.** Put the work on a feature branch and open a pull request.
3. **Every change gets its own PR** (or an update to an existing open PR that still matches the same ask). Do not leave committed work only on a local branch.
4. **If the PR is no longer valid, take it back.** Do not leave a stale, wrong, or abandoned PR open.

## GitHub MCP only

1. Call `GetDynamicTools` for the GitHub MCP namespace (e.g. `user-github` / `cursor-github`) before the first GitHub step.
2. Create PRs, add comments, close PRs, and manage remote branches **only** through that MCP.
3. Local `git` CLI is fine for filesystem work (status, diff, commit, checkout, local branch delete). Do **not** inject tokens or open credential UI for remote GitHub API work.
4. On `needsAuth`, 401, or 403: authenticate the GitHub MCP once, then retry **once**.
5. If GitHub MCP is still unavailable or missing a required tool: **stop immediately**, tell the human what failed, and that this skill uses **GitHub MCP only** — no `gh` or token fallback. Do **not** push to the default branch to work around it.

## When a PR is "no longer valid"

Treat it as invalid and retract when any of these are true:

- The user’s request changed or was cancelled, and the PR no longer matches.
- You found a better approach and the old PR would mislead reviewers.
- Checks fail for a reason you cannot fix without rewriting the intent.
- The change was already landed another way, or the branch is obsolete.
- You opened the PR by mistake, against the wrong base, or with secrets/bad files.
- Continuing would create noise or risk a bad merge.

## Open a PR (required after any change)

1. Create or update a descriptive branch off the default branch (local git).
2. Commit only the intended files; keep the message clear.
3. Push the branch with local git (no token injection).
4. **Open the PR with GitHub MCP** — short title and body that explain *what* and *why*, base = default branch unless the user named another.
5. Report the PR URL to the user when it is ready.

## Retract an invalid PR (GitHub MCP)

When the PR is no longer valid:

1. **Close the PR via GitHub MCP** with a one-line comment stating why (e.g. “Retracting: approach superseded” or “Retracting: request cancelled”).
2. **Delete the remote feature branch via GitHub MCP** if nothing else depends on it.
3. **Drop or reset the local branch** so you do not keep shipping the bad change.
4. Tell the user you retracted it and give the closed PR URL.

Do **not** merge an invalid PR. Do **not** leave it open “just in case.”

## Do not

- Use `gh`, curl, or env tokens for GitHub API / PR actions.
- Force-push or commit directly to the default branch to “skip” the PR.
- Quietly abandon an open PR you know is wrong.
- Retract a PR that is still valid and waiting on review unless the user asks.