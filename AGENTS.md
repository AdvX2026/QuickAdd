# AI Agent Instructions

This file is the single source of truth for all AI coding assistants working on this project.
Tool-specific files (`CLAUDE.md`) point here.

Keep it to durable, cross-session guidance — product, rules, standards, security, handoff. Session scratch (current branch, this round's progress, temporary state) does not belong here; put it in the End-of-Session Summary or `notice.md`.

## Product

QuickAdd (闪记) turns loose natural language into structured calendar events and reminders. What distinguishes it is that capture runs in both directions: not only planning ahead (`future`) but **back-logging** (`past`) — writing already-finished activity into the calendar as a retrospective archive. Classification is semantic: every calendar (工作/创意/学习/个人/生活/旅行/睡眠/日历) carries a definition written in settings and injected into the system prompt, and the model decides where an item belongs.

A **single-user iOS app**, deployment target iOS 26.5, built on SwiftUI with Liquid Glass, SwiftData and EventKit, extracting through DeepSeek (`deepseek-v4-flash`, OpenAI-compatible API). No server and no accounts; data lives on the device and in the user's own iCloud calendars. Not intended for public distribution — shipping would first require changing how calendar definitions work (see `QuickAdd/QuickAdd/Settings/notice.md`).

## Project Phase

- **QuickAdd (iOS app)**: M0 complete and accepted. Text in → extraction → draft review and editing → written to the matching calendars and reminder lists, with SwiftData recording every step; settings cover model config, calendar definitions, and write formatting. The PRD §11 acceptance input hit all six expectations across three runs with nothing dropped (2026-08-08, recorded in PRD §11); the write path and on-device use are both verified. 69 unit tests cover extraction parsing, validation rules, write formatting, and calendar config merging.
- **Next**: M1 voice input (`SpeechAnalyzer` + `SpeechTranscriber`). The input bar already reserves the microphone slot.
- **Known instability**: roughly 1 run in 9 drops an item outright — model behaviour, not an implementation defect. A reminder given a date but no time lands on either 18:00 or 23:59. See the measured baselines in the root `notice.md`.

## Development Rules

### Communication Language
- User-facing output — explanations, questions, status updates, summaries, anything the user reads — must be in Simplified Chinese (简体中文).
- Software and internal work stays in English: code, identifiers, comments, commit messages, logs, test names, and your own reasoning/analysis.
- This governs presentation, not content: do not rename existing identifiers or rewrite existing English docs just to comply, and match the surrounding language of any file you edit.

### Two-Step Confirmation First
- Never start the moment a requirement is stated or changed. Every new or modified requirement first passes through an understand-and-confirm step before any code is written. The only exception is trivial mechanical actions whose intent is obvious (e.g. `git push`, fixing a typo, a one-line rename).
- **Step one — reflect and surface, always in the open before building:**
  - Judge whether the request is sound: is it safe? is it efficient? does it fit the project's scale?
  - Consider whether a better approach exists than the one asked for.
  - State your full understanding of the request, your analysis of it (risks, tradeoffs, anything ill-advised), and your concrete recommendation.
- **Step two — act on the outcome:**
  - If the request is uncertain (multiple approaches with tradeoffs, may affect other features, or ill-suited to the project's scale), wait for the user's confirmation before modifying code.
  - If there is a clearly optimal and safe path, you may proceed without waiting for confirmation — but conspicuously notify the user that you are doing so up front, and on completion state plainly what you changed and why it was the better path.
  - Push back on any request that compromises security, correctness, or runtime efficiency, even when explicitly asked.

### Dry-Run Requests
- When the user's prompt contains "dry-run", treat the request as read-only: do not modify code, files, or configuration.
- Respond with two things: (1) your complete understanding of the request, and (2) a detailed, step-by-step explanation of how you would execute it.
- Make changes only after the user explicitly asks you to proceed.

### Simplicity First
- Write the minimum code that solves the stated problem; nothing speculative.
- No features, flags, config, or abstractions that weren't requested. Don't build "flexibility" for a future that isn't here.
- A single-use helper needs no abstraction — inline first, extract only on the second real caller.
- Validate untrusted input at the trust boundary, but don't add defensive handling for inputs that cannot occur.
- Adding a new third-party dependency needs the user's OK first; prefer the standard library and what's already in the project, and say why the dep is worth its cost.
- Before finishing, ask: would a senior engineer call this overcomplicated? If yes, cut it down.

### Scope Discipline
- Each task must stay within its stated scope. Do not add, refactor, or "improve" anything outside the current request.
- If the current task logically depends on another unbuilt feature, ask the user before implementing it. Never silently introduce adjacent functionality.
- Match the surrounding style and patterns even if you'd do it differently; don't reformat or refactor code your task doesn't touch.
- Clean up only the orphans your change creates (now-unused imports/vars/functions). Pre-existing dead code: flag it, don't delete it.

### Coding Standards
<!-- TODO: Replace the bullets below with this project's real standards. Keep each one concrete and enforceable, not a platitude. Delete what doesn't apply. -->
- **Source of truth & persistence**: TODO — the single source of truth for state, and how/where it is persisted.
- **Architecture & boundaries**: TODO — module/layer boundaries, dependency injection, what must stay free of UI/framework imports so it remains testable.
- **Language / framework conventions**: TODO — follow existing conventions; note key idioms and any banned APIs or patterns.
- **Security boundary**: TODO — the project's trust boundary; never execute downloaded or arbitrary code; never expose a control surface beyond the intended users.

### Secrets & Sensitive Data
- Never hardcode secrets or credentials; read them from environment/config. Never print, log, or echo secrets, tokens, or PII.
- Keep the project's seeded secrets-deny rules (covering `.env*`, `secrets/**`, and key files) in place.

### Verify & Commit
- Before coding, restate the task as a concrete, checkable success criterion rather than "make it work", and scale testing to the work's risk.
- After any code change, run the project's verification (e.g. type-check / build / lint) across all affected packages.
- If verification fails, fix the errors first, then verify again.
- After verification passes, automatically commit files that were modified by the agent in the current task and belong to the current task.
- Before committing, inspect dirty files and separate current-task agent edits from unrecognized dirty files. Do not include unrecognized dirty files in commits unless the user explicitly asks to include them.
- If a dirty file's ownership or task relevance cannot be determined safely, stop and ask the user before committing.
- Group commits by coherent change unit. Do not push unless explicitly requested.
- Branching: `feat/*` for features, always. Otherwise branch **only when the change unit spans more than one commit, or might be abandoned partway**. A merge commit earns its place by framing several commits as one unit; a single-commit branch just doubles the log entries and buries the mainline under `Merge branch` lines. One-commit fixes, docs, and config go straight to the mainline.
- Keep merged `feat/*` branches as historical archives — never delete them, and **push them**: an archive that exists on one machine is not an archive. Merged `fix/*` and `docs/*` branches hold nothing their merge commit does not, and can be pruned.
- Commit message format (Conventional Commits):
  ```
  type(scope): short summary

  Detailed description of what changed and why.
  ```
  Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `ci`, `perf`.

### Project Profile

<!-- PROFILE-SETUP (one-time): this template ships multiple rule profiles below.
     Before real work: (1) infer the project type, (2) ask the user which profile
     fits — use the platform's structured question mechanism if available,
     otherwise ask directly, (3) keep that PROFILE block, delete the others and
     this setup note, then commit. Until resolved, treat all profile-gated rules
     below as INACTIVE. -->

<!-- PROFILE:service START -->
**Profile: service / backend** — long-running services, APIs, anything with a datastore or external callers.
- Tests are required: cover new behavior; for a bug, first add a test that reproduces it, then make it pass.
- Validate and normalize every input crossing the trust boundary; never trust client-supplied values.
- **Data integrity & concurrency**: TODO — transactional boundaries, how concurrent writes are serialized, and idempotency for external callbacks. Fill in for this project.
<!-- PROFILE:service END -->

<!-- PROFILE:tool START -->
**Profile: lightweight tool / script** — one-off scripts, small CLIs, utilities.
- Scale verification to the risk: a documented manual check or a smoke test can be enough; don't build a test harness a small tool doesn't warrant.
- Skip layered architecture and speculative abstraction; keep it a small, readable unit.
<!-- PROFILE:tool END -->

### Session Handoff
- `notice.md` files are scoped by directory and record durable handoff information for the next agent.
- At the start of a task, read the relevant `notice.md` files (the root one and those in the directories you'll work in) before making changes.
- Root `notice.md` records global, cross-package, or cross-task project information.
- App/package notices record durable facts for that app/package: architecture, contracts, workflows, credentials, known limitations, and package-specific gotchas.
- Update the relevant `notice.md` only when the session creates or discovers information that remains useful beyond the current task or conversation. Do not record pure Q&A, routine progress, temporary decisions, or workflow session/journal details there.
- Ensure any `notice.md` you touch remains accurate and up-to-date within its directory scope.

### End-of-Session Summary
- At the end of each conversation, output a brief summary in 中文 (Chinese). This summary is user-facing.
  ```
  ## Summary
  - **Done**: work completed this round
  - **Key decisions**: tag each [user] or [self], explain the decision
  - **Commits**: list this round's commits (hash, message, files); note any dirty files left out and why
  - **Open/known risks**: issues introduced or discovered this round (omit if none)
  - **Suggested next steps**: 1-3 concrete actionable items
  ```
