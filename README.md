<div align="center">

# Neat

**A small native macOS app that turns saved TikTok and Threads posts into clean folders on disk — downloaded, transcribed, OCR'd, and mined for the tools they recommend, one self-contained folder per post.**

![Swift](https://img.shields.io/badge/Swift-6-FA7343?style=for-the-badge&logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-0B84FF?style=for-the-badge&logo=swift&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-26-000000?style=for-the-badge&logo=apple&logoColor=white)
![Status](https://img.shields.io/badge/status-v0.1.0-blue?style=for-the-badge)
![Tests](https://img.shields.io/badge/tests-151_passing-brightgreen?style=for-the-badge)

[About](#about) · [How it works](#how-it-works) · [Output](#output) · [Getting started](#getting-started) · [Configuration](#configuration) · [Project layout](#project-layout) · [Status](#status)

</div>

## About

You save things on TikTok and Threads and never see them again. Neat takes those links and
turns each one into a folder you actually own: the media, a transcript of the audio, the text
that was on screen, and a short list of the tools and links the post actually pointed at —
which you can send to a Notion database one row at a time.

The non-obvious decision is **what Neat refuses to do**. It does not organize, tag, rename,
or search. It writes plain folders and stops. A separate Claude Code session reads those
folders and does the organizing — which means the intelligence lives in prompts that are
cheap to change, not in an app that would need shipping every time the taxonomy moves.
Holding that boundary is the only reason this stays a small app.

Extraction sits just inside that line, deliberately: it records what a post *points at* — a
tool, a repo, a URL that was visibly on screen — and never what a post is *about*. The Notion
push is a button you press per resource, not a sync.

The second decision: **on-screen text is a first-class channel, not a bonus.** In tech
content the substance is usually typed on the screen — tool names, CLI flags, code — while
the audio is filler. An app that only transcribes audio would miss the point of most of
these posts.

The third: **each source gets its own list.** A sidebar separates TikTok from Threads, with
Instagram, YouTube and Reddit named and greyed out so the shape is visible, plus one Library
entry — Resources — that cuts across every source. That is only a statement of where an item
came from, which the folder name already encodes.

## How it works

Paste individual links or TikTok collection links, including shortened share links. Neat
lists the collection with your signed-in TikTok session in Chrome, then normalizes each
post to a canonical ID. Overlapping collections and individual links share the same dedupe;
importing a collection again queues only unseen posts. Each post then runs four stages:

| Stage | What it does |
| --- | --- |
| **fetch** | `yt-dlp` pulls the media and metadata, `ffmpeg` extracts audio and keyframes. TikTok extraction is flaky, so each call is retried three times inside the stage before the item spends one of its two real attempts — then it is marked dead. |
| **transcribe** | WhisperKit (`large-v3` turbo, 632 MB, on-device), auto language detect — the source material is mixed Hebrew and English, often mid-sentence. Slideshows are marked *skipped*, not retried forever. |
| **onscreen** | Vision reads every frame locally; a frame goes to the Anthropic API only if Vision found nothing, mean confidence fell below 0.45, or the text is Hebrew or Arabic. |
| **extract** | One Groq call reads the caption, transcript, on-screen text and up to five frames, and writes `resources.json` — the tools, repos and links the post recommended. Without a key it marks itself *skipped* and everything else still works. |

TikTok media comes from `yt-dlp`. Threads has no `yt-dlp` extractor at all, so Neat reads the
post's public embed page directly — no login, no browser. The post body lands in `body.txt`
and its attachments in `frames/`, so the rest of the pipeline never branches on source.

Each stage records its own version. Bumping one constant re-runs **only** that stage across
the whole library, leaving the rest intact — which matters because on-screen extraction gets
tuned repeatedly.

Everything is idempotent and resumable. Re-running never redoes finished work, and the
ledger remembers dead links so a months-old saved list does not retry its rot forever.

## Output

```
~/Neat/
  ledger.json
  items/
    tiktok-7381234567890/
      item.json        # url, id, author, caption, type, stage state
      transcript.txt
      onscreen.txt
      body.txt         # Threads posts only — the post body
      resources.json   # what the post recommended, and what has gone to Notion
      media/           # originals, full resolution
      frames/          # OCR input — keyframes, slides or post images
```

`frames/` is deliberately type-agnostic: video keyframes, slideshow slides and post images
all land there with the same naming, so the OCR stage never has to branch on type.

## Getting started

**Requirements:** macOS 26, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and
`yt-dlp` + `ffmpeg` on your `PATH`.

```bash
brew install xcodegen yt-dlp ffmpeg
```

Neat checks for `yt-dlp` and `ffmpeg` at launch and shows you the install command if either
is missing, rather than failing somewhere confusing later.

```bash
make gen     # generate Neat.xcodeproj from project.yml
make test    # run the module tests (no Xcode needed)
make build   # build the app
```

`project.yml` is the source of truth — `Neat.xcodeproj` is generated and gitignored, so
never edit it by hand.

| Command | Does |
| --- | --- |
| `make gen` | Regenerate the Xcode project from `project.yml` |
| `make test` | `swift test` in `Packages/NeatKit` — fast, no Xcode |
| `make build` | Full macOS app build |
| `make run` | Build and launch |
| `make shot OUT=x.png` | Screenshot the running window |
| `make dmg` | Build a styled installer DMG into `release/<version>/` |
| `make clean` | Remove the generated project, build output and the DMG venv |

To exercise the whole pipeline from a terminal without the window, against a throwaway
folder rather than `~/Neat/`:

```bash
cd Packages/NeatKit && swift build
.build/debug/neat-cli /tmp/neat-scratch "https://www.tiktok.com/@user/video/123"
```

To verify a collection's import and repeat-import counts without downloading its media:

```bash
.build/debug/neat-cli /tmp/neat-scratch --intake-only "<TikTok collection or share URL>"
```

Collection listing needs Chrome with a TikTok session. macOS may ask to allow yt-dlp access
to Chrome's saved cookies. Neat shows a loading indicator while listing and a readable error
if the collection is private, empty, or returned an incomplete listing.

## Configuration

Everything works with no keys at all — download, transcription and on-screen text are entirely
on-device. Keys only add the optional parts.

```bash
cp .env.example ~/Neat/.env   # then fill in what you want
```

| Key | Enables | Without it |
| --- | --- | --- |
| `GROQ_API_KEY` | the **extract** stage | the stage marks itself *skipped* |
| `NOTION_TOKEN` | pushing resources to Notion | the Notion buttons are disabled |
| `NOTION_RESOURCES_DB_ID` | the database to push into | same |
| `ANTHROPIC_API_KEY` | the OCR fallback for low-confidence or non-Latin frames | Vision's result is kept as-is |

Values are read from the process environment first, then `~/Neat/.env`, then the Keychain.
The names match the ones used in Sky, so a `.env.local` there copies straight across.

**A dotfile is plaintext on disk.** The Keychain is the safer store and is still preferred
when a key is present there; the app's own key sheet writes to the Keychain only. `.env`
exists because it is faster to paste into.

The Notion database needs these exact property names: `Name` (title), `URL` (url), `Status`
(select), `Category` (multi-select), `Description` (rich text). Notion rejects the whole write
on an unknown property.

## Project layout

The modules are one local SPM package with a strictly one-way dependency graph, so the seams
are enforced by the compiler rather than by good intentions:

```
NeatUI → NeatPipeline → NeatAdapters → NeatCore
```

| Module | Responsibility |
| --- | --- |
| `NeatCore` | Canonical IDs, ledger, item model, stage versions. No UI, no platform code. |
| `NeatAdapters` | `TikTokAdapter` and `ThreadsAdapter`, URL canonicalization including short-link resolution, and the pure Threads embed-page parser. |
| `NeatPipeline` | The four stages, the Threads fetch, the Notion client, secrets resolution, the subprocess runner, and the launch preflight check. |
| `NeatUI` | The one window — a three-column split view: sources, queue, resource inspector. |

Plus `neat-cli`, an executable target that runs the same pipeline headlessly.

## Status

Built in milestones, and honest about where it is:

| | Milestone |
| --- | --- |
| ✅ | **M0** — project scaffold, module skeletons, empty window |
| ✅ | **M1** — canonical IDs, ledger, paste parsing, the new/have/unavailable summary |
| ✅ | **M2** — fetch stage, type detection, real folders, resume |
| ✅ | **M3** — transcription |
| ✅ | **M4** — on-screen text extraction |
| ✅ | **M5** — the UI pass |
| ✅ | Threads, end-to-end, via the public embed page |
| ✅ | The `extract` stage and `resources.json` |
| ✅ | The Notion push, with duplicate detection |
| ✅ | A styled installer DMG (`make dmg`) |

151 tests across 28 suites pass. Four things are written and believed correct but have
**never been run against reality**, and are not being called done:

| Not verified | Why |
| --- | --- |
| the Groq **extract** path | no API key was available — the model's handling of images plus a JSON schema in one request is untested |
| the **Notion** push | no token was available — neither the duplicate filter nor a real page create has run |
| the **Anthropic** OCR fallback | unit-tested for shape, never sent to a live endpoint |
| the **slideshow** fetch path | no public photo-mode post could be found to test against |

**Deliberately not built:** search, tagging, editing, a second window. Harvesting your saved
Threads list still needs a logged-in `WKWebView` and is not built — only fetching a post you
already have the link to. The reasoning for all of it is in `DESIGN_SPEC.md`, and `PLAN.md`
is the ordered list of what comes next.
