---
name: armin-dev-policy
description: >
  Unified mandatory development policy for this project. Apply on every feature,
  fix, refactor, review, naming choice, version bump, architecture/DB decision,
  anti-pattern check, signing/release step, and About Me / WebUI standards work.
  Merges detect-anti-pattern, digital-signature, software-architecture,
  software-engineer-principles, software-versioning, variable-naming,
  armin-principles-database, armin-principles-software-engineering, and
  database-architecture into one skill.
disable-model-invocation: false
metadata:
  version: "2.0.0"
  author: Armin Dashti
  category: policy
  tags: [policy, architecture, naming, versioning, database, anti-pattern, unified]
---

# Armin development policy (unified)

## Hard rule

**During any development in this project, follow this skill end-to-end.** It is the single source of policy. Do not skip sections because a change "looks small." Explicit user instructions for *this* task win for that task only; otherwise this policy wins over generic defaults.

Companion files in this skill folder: `reference-anti-patterns.md`, `reference-architecture.md`, `standards/about-armin/`.

---

## 1. Software engineering principles

1. Prefer clarity, small blast radius, and reversible steps.
2. Match the repo's real stack; do not invent ceremony the team cannot operate.
3. Protect domain invariants in code, not only in UI or docs.
4. Do not leave dead abstractions, copy-paste modules, or "temporary" hacks without a tracked follow-up.
5. Before finishing: naming, boundaries, versioning, and data design still match the sections below.

---

## 2. Variable naming

1. If the user **explicitly** demands a name, use it. Casual suggestions may be improved to modern standards.
2. Never rename existing identifiers unless asked.
3. Never use placeholders in new code (`foo`, `bar`, `temp`, `data`, `obj`, etc.).
4. Clarity over brevity; names encode domain meaning, not types.
5. **Variables:** `camelCase` (JS/TS/Java) or `snake_case` (Python/Rust).
6. **Booleans:** `is` / `has` / `can` / `should`; state positive truths.
7. **Functions:** Verb + Noun (`normalizeInvoiceLineItems`, `fetchSubscriptionTier`).
8. **Classes/Types:** `PascalCase`; avoid generic `Manager` / `Handler` when a domain name exists.
9. **Interfaces:** no `I` prefix for TS shapes; contracts may use `-able` / `-er`.
10. **Constants:** `SCREAMING_SNAKE_CASE` for primitives; `PascalCase` for enums.
11. **Hooks/handlers:** `use…`, `handle…`.
12. **Files:** Components/Types `PascalCase.tsx`; utils/dirs `kebab-case`; Python `snake_case`; Go packages single lowercase word.
13. Prefer precise verbs: fetch/derive, assign/persist, patch/reconcile, revoke/purge, validate/verify, dispatch/emit, execute/orchestrate, construct/compose.

---

## 3. Software versioning

Apply whenever versions, tags, changelogs, or release identity are involved.

1. Strict SemVer `MAJOR.MINOR.PATCH` only.
2. Maintain root `CHANGELOG.md`; record every bump.
3. Never alter a released version; fix with a new bump.
4. Prefer `v` prefix on tags (`v1.2.3`).
5. Start at `0.1.0`; move to `1.0.0` when production-ready.
6. **MAJOR** breaking; **MINOR** backward-compatible features; **PATCH** fixes.
7. Pre-release suffixes only when needed (`-alpha`, `-beta.1`, `-rc.1`).
8. Workflow: detect current version → classify change → bump → write changelog → tag.

---

## 4. Software architecture

When proposing or changing architecture:

1. Capture goals, constraints, workload, quality needs, and non-goals first (infer from repo when possible).
2. On brownfield, assess current structure before recommending a target; prefer incremental modularization over big-bang rewrite unless asked.
3. Defaults:
   - Small/medium one-team API → **modular monolith** + vertical modules.
   - Rich domain, long-lived → modular monolith with **Clean/Hexagonal** inside modules.
   - Simple CRUD / tiny team → layered or vertical slices; avoid ceremony.
   - Microservices **only** when independent deploy/scale/ownership and data ownership are real.
4. Prefer one deployable until independent deploy/scale is required.
5. Document: primary style + why, dependency rule, module/layer map, cross-cutting, data ownership, rejected alternatives, adoption phases.
6. Never propose microservices as a default "best practice."
7. Never implement a large restructure without explicit approval.
8. Decision cues: [reference-architecture.md](reference-architecture.md).

---

## 5. Detect anti-patterns

When designing, reviewing, or after large features:

1. Scope the scan; map projects/layers/dependency direction.
2. Require **file/path evidence** for every finding.
3. Hunt: god objects, circular deps, shotgun/divergent change, layer leaks, fat controllers, feature envy, N+1, unbounded reads, distributed monolith, premature microservices, and related smells.
4. Severity: Critical / High / Medium / Low. Confidence: Confirmed / Suspected.
5. Report with evidence, why it hurts, and a concrete scoped fix. Do not invent smells; do not treat style nits as architecture anti-patterns.
6. Do not refactor while reporting unless asked to fix.
7. Catalog detail: [reference-anti-patterns.md](reference-anti-patterns.md).

Report shape:

```markdown
# Anti-pattern report — <scope>
## Summary
- Confirmed: N | Suspected: M | Scanned: <paths>
## Findings
### 1. <Name> — <Severity> (Confirmed|Suspected)
- Evidence: `path` — <fact>
- Why it hurts: …
- Fix: …
```

---

## 6. Database architecture and Armin DB principles

When touching schema, persistence, or data rules:

1. Prefer clear ownership of data per module/bounded context; avoid a shared integration database across services by default.
2. Model invariants close to the data that owns them; avoid unbounded list queries and N+1 hotspots.
3. Name tables/columns with domain clarity; keep migrations additive and reversible when possible.
4. Prefer PostgreSQL when stating greenfield defaults unless the repo already standardizes another engine.
5. Align transactions and consistency with the architecture section (one deployable vs split ownership).

*(Upstream `database-architecture` and `armin-principles-database` bodies were stubs; this is the unified policy.)*

---

## 7. Digital signature

When shipping signed artifacts, installers, or release integrity:

1. Prefer established signing tooling for the platform.
2. Never commit private keys or passwords into the repo.
3. Verify signatures in CI or release checks when the project already signs builds.
4. If signing details are missing for this repo, stop and ask rather than inventing a key path.

*(Upstream `digital-signature` was a stub; follow these rules and any repo-specific signing docs.)*

---

## 8. About Me / WebUI identity standards

When creating or editing About Me / About pages:

1. Route `/about-me` (or equivalent); title `About Me`; tagline `Armin Dashti — vibe coder, conductor of craft.`
2. Layout: header; portrait + three bio paragraphs; Interests; obfuscated Contact; English then Persian quotes.
3. Portrait: `public/about-me/armin.png` (see `standards/about-armin/`).
4. Bio beats in order: vibe coder identity; Cursor AI authorship with Armin as reviewer; craft (prefer Go services, Vue front ends, PostgreSQL when stating defaults).
5. Email — never contiguous in static source; build `mailto:` at runtime from parts; visible `arminonline71 [at] gmail [dot] com`.
6. Interests: cars, movies, vibe coding, coding, politics, military, jet fighters, aircraft.
7. Closing quotes verbatim (English Anonymous + Persian). Full copy: `standards/about-armin/description.md`.
8. Never invent private details; never replace the quotes.

---

## Conflicts

- Explicit user task instructions win for that task.
- More specific section wins (e.g. DB rules for schema work).
- Note conflicts to the user when two sections pull different ways.
