# Neat

A small native macOS app that turns saved social posts into clean folders on disk.

Paste TikTok or Threads links → Neat downloads the media, transcribes the audio, reads the
on-screen text, lists the resources the post pointed at, and writes one self-contained folder
per item. **That is the entire job.** Neat never organizes, tags, or renames — a separate
Claude Code session reads those folders and does that. A feature that is really organizing
belongs in that session. Extraction is the one deliberate exception, and sits just inside the
line: it records what a post *points at*, never what a post is *about*.

## Stack and layout

Swift 6, SwiftUI, macOS 26. No AppKit unless there is genuinely no alternative. `yt-dlp` and
`ffmpeg` are resolved from `PATH`, not bundled. `project.yml` is the source of truth —
**`Neat.xcodeproj` is generated and gitignored.** Edit the YAML, then `make gen`; never edit
the pbxproj.

Modules are one local SPM package, `Packages/NeatKit`, with a strictly one-way dependency
graph. `NeatCore` imports nothing and must never import SwiftUI or AppKit:

    NeatUI → NeatPipeline → NeatAdapters → NeatCore

- `NeatCore` — IDs, ledger, item model, stage versions. No UI, no platform code.
- `NeatAdapters` — `TikTokAdapter`, `ThreadsAdapter`, and the pure Threads embed parser.
- `NeatPipeline` — the four stages (`fetch`, `transcribe`, `onscreen`, `extract`), the Threads
  fetch, `NotionClient`, `SecretsStore`, tool preflight.
- `NeatUI` — the one window: a three-column split view (sources · queue · resource inspector).
  A source is only where an item came from — not the content organizing Neat excludes.

Plus `neat-cli` — `.build/debug/neat-cli <root> <url>...` runs the whole pipeline headlessly.

## Commands

    make gen     # regenerate Neat.xcodeproj from project.yml
    make test    # swift test in Packages/NeatKit — fast, no Xcode
    make build   # full macOS app build
    make shot OUT=x.png   # screenshot the running window
    make dmg     # styled installer DMG → release/<version>/ (see Scripts/build-dmg.sh)

## Output contract

Everything lands under `~/Neat/`. This shape is the product; other tools depend on it.

    ~/Neat/ledger.json          ~/Neat/.env   # optional keys, see .env.example
    ~/Neat/items/tiktok-7381234567890/
        item.json  transcript.txt  onscreen.txt
        body.txt        # Threads only — the post body
        resources.json  # what extract found; never clear pushedToNotion
        media/     # originals, full resolution
        frames/    # the generic OCR input dir, whatever the item type

`frames/` is type-agnostic on purpose: video keyframes, slideshow slides and post images all
land there with the same naming, so no stage branches on type.

## Traps that have already cost a day

**Read the trap table in `PLAN.md` before touching ffmpeg, the icon, the DMG or WhisperKit** —
every entry is a silent failure with a misleading error. The one that bites hardest:

- **Threads' User-Agent is inverted.** A *browser* UA gets an empty JS shell; a plain
  non-browser UA gets the server-rendered HTML. `ThreadsFetch.userAgent` must stay
  non-browser. Per-post fetch needs no login and no `WKWebView`; harvesting the saved list
  still does.

## Non-negotiables

**Never overwrite.** If a file exists, read it and propose a diff — source files, `CLAUDE.md`,
`README.md`, `project.yml`, all of them. Assume anything on disk was hand-edited; merge.

**Idempotent.** Every stage re-runs safely; nothing is processed twice. Writes are atomic
(temp file + rename). **The folder on disk wins over the ledger** — if `item.json` says a
stage is done, believe it.

**Stage versions gate re-runs.** Each stage records `{done, skipped, v}`. Bumping a constant in
`StageVersions` re-runs exactly that stage library-wide on the next sweep, leaving every other
stage's output intact. `skipped` ≠ `done`: the stage does not apply (a slideshow has no
speech) and must never be retried.

**Never claim a UI task is done without having looked at a screenshot of it.** Take it, open
it, list what is wrong, fix it. `make shot` exists for this.

**System components first.** Standard SwiftUI controls adopt Liquid Glass automatically on the
macOS 26 SDK. Apply `.glassEffect` by hand in exactly two places — the drop well and the queue
rows. No hand-rolled toolbars, no `.ultraThinMaterial` stand-ins, no decorative shadows or
borders, never glass on glass. Writing custom chrome? Stop and ask first.

**The queue is a real `List(selection:)`. Do not replace it with a tap gesture.** A
`ScrollView` + `onTapGesture` looks simpler and silently loses single-click select,
double-click, arrow keys, type-select, multi-select, Delete and VoiceOver. It was already
tried; clicks did not register.

**Local only, no database.** State is JSON files under `~/Neat/`. Network calls: media, the
Threads embed page, and three optional APIs (Groq, Notion, Anthropic). Keys come from
`SecretsStore` — environment, then `~/Neat/.env`, then Keychain — and are never logged. The
in-app key sheet writes to Keychain only.

**`ExtractStage.model` is a Groq *preview* model** (`qwen/qwen3.6-27b`), picked because it does
vision *and* JSON-schema structured output in one request. Expect to swap it; that is why it is
one constant. No Groq key → the stage marks itself `skipped`, never fails. **Neither the Groq
nor the Notion path has ever run against a live API.**

## Before writing code

Read the docs, not your memory — the Liquid Glass APIs are new and easy to hallucinate. Use
Context7; for Apple APIs prefer the SDK's own `.swiftinterface` over the doc website, which
does not render for fetchers. Verified signatures are in `DESIGN_SPEC.md`.

- `DESIGN_SPEC.md` — milestones and what is unverified, verified Liquid Glass signatures, the
  subprocess traps in full, the icon and DMG pipelines, the Notion schema, the Threads
  findings. Read it before starting a milestone.
- `PLAN.md` — the handoff: state of play, ordered next steps with acceptance criteria, and
  every known trap in one table.

