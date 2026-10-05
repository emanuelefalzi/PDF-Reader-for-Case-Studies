# How it was built

This app was built in under three weeks (14 September to 2 October 2026) by one person directing **Claude Code** as an AI engineering team.
My role was product owner, designer and tester: I decided what to build and why, set the quality bar, and checked every milestone on my own study material. The agents wrote the code under rules I set.
This page describes the method, because it is as much the point of the project as the app itself.

## 1. Spike first, then a specification

Before any code, a one-day spike verified the risky assumptions on the real machine (MacBook Air M1, 8 GB) with the real CLI and the real PDFs:

- the exact `claude` CLI flags for isolated, schema-constrained calls, and where the structured output arrives;
- whether a single streaming process can sustain a multi-turn chat, and how fast the first token is;
- that the PDFKit, SwiftUI and AppKit APIs the design depends on actually exist in the macOS 26 SDK;
- cost and quality of one analysis call at different effort levels (low effort lost two of the four mark types, so the default stays).

The results became §4 of [`SPEC.md`](../SPEC.md), "Facts already verified". The first draft of the spec was then critiqued by a second, independent agent; the issues it raised (index mapping across pages, concurrency with PDFKit, budget and replay of real calls, multiple windows, iCloud "dataless" files, read-only PDF guarantees, and more) shaped v2.
Every requirement is tagged **[DECIDED]** (my call) or **[TECHNICAL CHOICE]** (the agent's call, which can be revised if it is recorded).

## 2. Autonomous build, milestone by milestone

The build ran milestone by milestone (M0-M10, see SPEC §11), each with explicit completion criteria: for example, "the header of the Draghi report is removed on at least 95% of pages" or "a renamed PDF finds its data again".
Standing rules for the agents (SPEC §10.3), among them:

1. Follow the milestones in order; do not widen the scope beyond the spec.
2. Do not stop to ask: decide, write the decision down in the build decision log, and continue.
3. Heavy work goes to sub-agents; the main session coordinates, verifies and keeps the hand-over file up to date.
4. Test PDFs are read-only: never modified, never copied into the repository.
5. Respect a fixed budget of real Claude calls (80 analysis, 25 chat), each one logged with tokens and timing.
6. Prompts and JSON schemas live in `Resources/`, never inside the code.
7. A local commit at the end of each milestone, with build and tests green.

State lived in files, not in the conversation: a hand-over document recorded the current milestone, the next exact step, open issues and calls spent, so a session could hit a usage limit or a full context and resume cleanly.

## 3. Tests that do not need Claude

A fake Claude CLI ([`scripts/fake-claude/`](../scripts/fake-claude/)) lets the full suite run offline: success, invalid JSON, timeout, logged-out user, rate limit and streaming chat are all scripted scenarios.
Real calls are opt-in (`LELEPDF_REAL_CLAUDE=1`) and were used sparingly to validate prompts against real documents.
The suite grew to 950+ tests, including tests on real `NSWindow` and `PDFView` instances, data-loss regressions, and a performance bench with a memory guard.

## 4. Review rounds after v1

Once v1 worked, I used it daily and wrote down everything that felt wrong. That backlog became review rounds F4-F18, each with a written brief, a review report, numbered decisions and before/after measurements. Some examples:

- **Memory:** a 600-page synthetic PDF pushed the app to 604 MB against a 400 MB budget, because PDFKit kept its caches on the visible document; fingerprinting and extraction moved to short-lived PDFKit instances in batches, bringing it to about 300 MB.
- **Responsiveness:** the selection mini bar was rebuilt on every drag event (10.7 ms per event); now it is rebuilt once on mouse-up (0.2 ms).
- **A bug no unit test had caught:** in-place editing of a card had silently stopped working in the real panel; it was found because a UI test on the real `RewritePanel` hung, then fixed and covered.
- **Word export:** `.docx` files written with the user's own style template, matching styles by id or by name, verified against the real template.

Independent review agents (including Codex agents on separate git worktrees) checked each round against a written quality checklist (fluidity, macOS conventions, summary quality, data safety) before it was merged.

## 5. What I would point out

- Treating AI agents like a team needs the same things a team needs: a clear spec, explicit acceptance criteria, a decision log, and someone who actually uses the product and says what is wrong.
- Measuring beats guessing: every performance or memory claim in the project comes with a number taken on the target machine.
- Constraints shaped the design for the better: a cheap subscription plan and an 8 GB laptop led to on-demand analysis, one process at a time, and a test suite that does not spend any tokens.
