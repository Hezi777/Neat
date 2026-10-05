# Neat — session handoff

Written for an agent that has never seen this repo and cannot ask questions. It is
self-contained: everything you need to build the project, understand its rules, and pick up
the next piece of work is here or named here.

Two companion files, both accurate and both worth reading before you change anything:

- `CLAUDE.md` — the rules. Short on purpose.
- `DESIGN_SPEC.md` — the reasoning, the verified API signatures, and the long-form version of
  everything summarised here.

**The single most important rule: never overwrite a file.** Read it, then edit surgically.
Everything on disk may have been hand-edited.

---

## 1. What Neat is

A local-only macOS app. You paste TikTok or Threads links; it downloads the media,
transcribes the audio, reads the on-screen text, lists the tools and links the post pointed
at, and writes one self-contained folder per post under `~/Neat/`.

It deliberately does **not** organize, tag, rename, or search. A separate Claude Code session
reads those folders and does that. The folder shape is the product.

---

## 2. State of play

### Active follow-up — 2026-09-12

- **DMG artwork complete and visually accepted.** `Assets/dmg/background.png` now uses
  **1080×760 at 144 DPI**. Verified in Finder: the same 540×380-point layout, with sharp
  Retina artwork. This supersedes the earlier 540×380/72-DPI-only advice below. No packaging
  script changes were needed.
- **TikTok collections in progress.** The user identified Clipmine as Neat's predecessor.
  Inspected `/Users/hen/Developer/archive/clipmine`: its collection listing uses yt-dlp's
  flat playlist mode with Chrome cookies, followed by per-post processing. The user's
  shared link resolved to `@hen_zrihen/collection/AI-7599982720722815752`; a live listing
  returned **77 posts, 77 unique IDs**. No media downloads or Notion writes in that check.
- Added collection detection, share-link expansion before post dedupe, strict listing
  validation, UI loading/error feedback, and a CLI `--intake-only` mode for verifying imports
  without downloading a whole collection. Regression reproduced first: a numeric collection
  path was incorrectly accepted as a video ID. **Neat's live intake imported 77 posts**, in
  order, with post URLs rather than collection URLs. Reimporting the same short link together
  with an overlapping post returned **0 new, 77 already have**. Verified against a temporary
  library, leaving `~/Neat/` untouched. **159 tests in 29 suites pass; `make build` succeeds.**
- **Sidebar stutter under investigation.** User reports a hitch when showing the collapsed
  sidebar. Consulted Apple's NavigationSplitView and macOS Tahoe guidance. Preserve the native
  toggle and existing design; do not claim fixed before observing repeated hide/show cycles.
- **Rate limits no longer kill items — 2026-09-14.** `ExtractStage` retried nothing and
  `Library` counted every API failure as one of an item's two permanent attempts, so two 429s
  marked a post `dead` when nothing about it was wrong. At collection scale a busy afternoon
  would have buried a large share of a 77-post run. There is now a distinct
  `StageError.rateLimited`: the stage retries a 429 up to three times honouring Groq's own
  `retry-after` (clamped to 60s), and `Library` withholds the attempt and re-queues instead of
  counting it. A 413 is *not* retried — it can never fit — and says to lower `maxImages`.
  Ten consecutive rate limits now leave an item at `attempts: 0, status: queued`.
- **Two smaller fixes.** `AppModel.init(paths:)` built its stages at the default root, so a
  model pointed at another library read `~/Neat/.env` while writing elsewhere. And
  `onscreen.txt` labelled its sections with the loop index, so `frame-01.jpg` was written as
  `frame 00` and no section could be matched back to its image; sections now carry the file's
  own name. That changed a product output, so `StageVersions.onscreen` went to **2** — the
  live library re-ran `onscreen` alone and left `fetch`, `transcribe`, `extract` and
  `resources.json` untouched, which is the first real exercise of the version mechanism.
- **Clipmine removed.** Preserved its architecture, exact collection/pacing behavior, OCR
  choices, storage tradeoffs, and known bugs in [CLIPMINE_HANDOFF.md](CLIPMINE_HANDOFF.md).
  Deleted `/Users/hen/Developer/archive/clipmine` after verifying that `data/` was empty,
  no source list needed migration, and no Clipmine process was running. Shared tools and
  browser sessions were left in place.

Sample member verification passed: `tiktok-7667767850118991135` downloaded and completed
WhisperKit transcription (1,864 characters) and Vision OCR (1,708 characters). The temporary
library had no API keys, so resource extraction correctly skipped; no Notion write was made.

Remaining acceptance checks: verify native sidebar behavior and UI screenshots, and run
final tests/build after all fixes. Collection import, repeat-import dedupe, a sample member's
local pipeline, architecture preservation, and old-project removal have passed.

| | Milestone | Verified? |
| --- | --- | --- |
| ✅ | **M0** — project scaffold, module skeletons, app launches | Yes |
| ✅ | **M1** — canonical IDs, ledger, paste parsing, new/have/unavailable summary | Yes, unit-tested |
| ✅ | **M2** — `fetch` stage, type detection, real folders, resume after a forced quit | **Video** verified end-to-end against a real post. **Slideshow path never tested.** |
| ✅ | **M3** — `transcribe` stage, WhisperKit on-device, `skipped` for no-speech items | Yes — 1218 accurate characters off a real video |
| ✅ | **M4** — `onscreen` stage, Vision locally + Anthropic fallback | Vision verified on real frames. Anthropic fallback **switched off by decision** — see §2. |
| ✅ | **M5** — UI pass: three-column split view, one spacing scale, light + dark | Yes, from screenshots |

Shipped after M5:

| | What | Verified? |
| --- | --- | --- |
| ✅ | **Threads per-post fetch** via the public embed page | Yes — three real public posts, end to end |
| ✅ | **`extract` stage** (4th stage, Groq) writing `resources.json` | **Verified live 2026-09-13** — two real resources off a real post. |
| ✅ | **Notion push** with URL-normalized dedupe and a duplicate prompt | Unit-tested only. **Never run against a real database.** |
| ✅ | **`SecretsStore`** — environment → `~/Neat/.env` → Keychain | Yes |
| ✅ | **Installer DMG** (`make dmg`) | Yes — builds, mounts, Finder draws the background correctly |

**176 tests across 33 suites, all passing** (`make test`, verified on this machine).

### Which paid paths have now been exercised — 2026-09-13

`~/Neat/.env` now holds `GROQ_API_KEY`, `NOTION_TOKEN` and `NOTION_RESOURCES_DB_ID`.
`ANTHROPIC_API_KEY` is present but **empty**.

- **Groq `extract` — verified live.** One real TikTok video produced a `resources.json` with two
  rows the post genuinely points at. It took four request-body fixes to get there; the shape
  that works is recorded in `DESIGN_SPEC.md` and the traps are in §9.
- **Notion — schema verified, no write yet.** The database resolves, and all five properties
  match the code exactly (`Name` title, `URL` url, `Status` select, `Category` multi_select,
  `Description` rich_text), with the ten `Category` options matching `Resource.categories`
  string for string. **No page has been created.** The duplicate prompt is still untested.
- **Anthropic OCR fallback — deliberately off.** The owner has decided not to add an
  `ANTHROPIC_API_KEY`. This is a settled choice, not a missing step: Vision's read stands as
  the final answer, which is exactly what the no-key path already does. The cost is accepted —
  stylised text stays garbled (`EMI-KOWALSI-SKE` for "Emil Kowalski" in this item's
  `onscreen.txt`). **Do not re-open this as an outstanding task.** If it is ever wanted, the
  path is built and reachable; only a key is missing.

---

## 3. Build, run, test, screenshot, package

Requirements: macOS 26, Xcode 26, `xcodegen`, and `yt-dlp` + `ffmpeg` on `PATH`.

```bash
brew install xcodegen yt-dlp ffmpeg
```

Run from the repo root:

```bash
make gen                  # regenerate Neat.xcodeproj from project.yml
make test                 # swift test in Packages/NeatKit — fast, no Xcode
make build                # full macOS app build (Debug)
make run                  # build, then launch the built app
make shot OUT=x.png       # screenshot the running Neat window
make dmg                  # styled installer DMG → release/<MARKETING_VERSION>/
make clean                # remove the generated project, build output, .dmgvenv, release/
```

`project.yml` is the source of truth. **`Neat.xcodeproj` is generated and gitignored — never
edit the pbxproj.** Edit the YAML and run `make gen`.

Headless pipeline run, against a throwaway root instead of `~/Neat/`:

```bash
cd Packages/NeatKit && swift build
.build/debug/neat-cli /tmp/neat-scratch "https://www.tiktok.com/@user/video/123"
```

It prints the paste summary, every state transition, and the final stage state per item. This
is the fastest way to verify a stage against a real post — much faster than launching the app,
and it never touches `~/Neat/`.

`make shot` exists because **XcodeBuildMCP ships no macOS window screenshot tool at any
workflow setting** (its `screenshot` is simulator-only). `Scripts/shot.sh` finds the window via
`CGWindowListCopyWindowInfo` and hands the id to `screencapture -l`. It exits nonzero when no
window is found, so a failed screenshot cannot pass silently as a green milestone.

---

## 4. The output contract

Everything lands under `~/Neat/`. **This shape is the product** — other tools read it.

```
~/Neat/
  ledger.json                 # per-item status, attempts, lastSeen
  .env                        # optional API keys (see §7)
  items/
    tiktok-7381234567890/
      item.json               # url, id, platform, type, author, caption, stage state
      info.json               # raw yt-dlp output, verbatim
      transcript.txt
      onscreen.txt
      body.txt                # Threads only — the post body
      resources.json          # {"v":1,"resources":[…]} — what extract found
      media/                  # originals, full resolution
      frames/                 # OCR input: keyframes, slides or post images
```

`frames/` is type-agnostic on purpose. Video keyframes, slideshow slides and Threads
attachments all land there with the same `frame-NN.jpg` naming, so no downstream stage ever
branches on where the item came from.

### The four stages

| Stage | Does | Marks `skipped` when |
| --- | --- | --- |
| `fetch` | TikTok: `yt-dlp` + `ffmpeg` for media, audio and keyframes. Threads: the embed page (§6). | never |
| `transcribe` | WhisperKit `large-v3-v20240930_turbo_632MB`, on-device, auto language detect (material is mixed Hebrew/English mid-sentence) | item type is `slideshow` or `image` — no speech to find |
| `onscreen` | Vision reads every frame locally; a frame goes to the Anthropic API only if Vision found nothing, mean confidence < 0.45, or the text is Hebrew/Arabic | a text-only Threads post has no frames (see §9, known wart) |
| `extract` | One Groq call over caption + `body.txt` + `transcript.txt` + `onscreen.txt` + up to 5 frames → `resources.json` | no `GROQ_API_KEY` is set |

### The versioning rule

Each stage records `{done, skipped, v}` in `item.json`. `StageVersions` (in
`NeatCore/Item.swift`) holds one constant per stage.

**Bumping one constant makes exactly that stage re-run library-wide on the next sweep, leaving
every other stage's output intact.** That is the whole point — on-screen extraction and the
extract prompt get tuned repeatedly, and re-downloading everything to retune a prompt would be
absurd.

`skipped` ≠ `done`. `skipped` means the stage **does not apply** to this item and must never be
retried. `needsRun` returns false for it forever.

---

## 5. Architecture in ten lines

```
NeatUI → NeatPipeline → NeatAdapters → NeatCore        (strictly one-way)
```

| Module | Holds | May import |
| --- | --- | --- |
| `NeatCore` | canonical IDs, ledger, `Item`, `StageVersions`, `Resource`, `ResourceURL`, `NeatPaths`, atomic writes | **Foundation only.** Never SwiftUI, never AppKit, never the filesystem conventions of a stage. |
| `NeatAdapters` | `TikTokAdapter`, `ThreadsAdapter`, `TikTokURL`, `ThreadsURL`, `ThreadsEmbed`, redirect resolution | NeatCore |
| `NeatPipeline` | the four stages, `ThreadsFetch`, `NotionClient`, `SecretsStore`, `ProcessRunner`, `ToolPreflight`, `Library` | NeatCore, NeatAdapters |
| `NeatUI` | the one window — `NeatRootView`, `AppModel`, `ResourcesView`, `NeatIcon`, `Theme` | everything below |

Stages know about the filesystem; `NeatCore` does not. URL parsing is pure and synchronous and
lives away from anything that touches the network, because dedupe is where this breaks.
`Library` owns `~/Neat/`: it enqueues, runs stages in order, and keeps the ledger honest.
Resume is not a special mode — `run()` just processes everything that still needs work.

---

## 6. Threads, in full

There is **no yt-dlp extractor for Threads.** Neat reads the public embed page:

```
https://www.threads.com/t/<shortcode>/embed/
```

Four things that are not obvious and cost real time:

1. **The User-Agent behaviour is inverted.** A *browser* User-Agent returns an empty JS shell.
   A plain, non-browser one returns the fully server-rendered HTML. This is the opposite of the
   usual scraping advice. `ThreadsFetch.userAgent` is `Neat/1.0 (+local archiver)` and must
   stay non-browser.
2. **No login wall** on this path.
3. **The `@username` segment is decorative** — the server ignores it. `ThreadsURL.embedURL` is
   built from the shortcode alone, so a stored URL whose account was renamed still resolves.
4. **A deleted or private post answers HTTP 200 with a shell.** `ThreadsEmbed.parse` throws
   `postUnavailable` when it finds neither text nor images. The status code lies; the content
   does not.

`ThreadsURL` accepts `threads.net` and `threads.com`, `/@user/post/CODE` and `/t/CODE` — all
four forms key to one folder. Body text → `body.txt`; attachments → `frames/` via the shared
`FrameExtractor`. Item type is `.image`, which is what makes `transcribe` skip itself.

**What is still missing: harvesting your saved list.** That is behind auth and is not
server-rendered anywhere, so it still needs the original plan — a persistent `WKWebView` logged
into once, with a *Sync saves* button that auto-scrolls the saved tab and harvests post URLs
via `evaluateJavaScript`. Only the per-post fetch escaped needing a browser.

---

## 7. Where the keys go

`SecretsStore` resolves each key in this order, first hit wins:

1. the process environment (so a terminal `neat-cli` run can override the app)
2. `~/Neat/.env`
3. the Keychain — **Anthropic only**, it is the only key ever stored there

```bash
cp .env.example ~/Neat/.env   # then fill in what you want
```

| Key | Enables | Without it |
| --- | --- | --- |
| `GROQ_API_KEY` | the `extract` stage | the stage marks itself `skipped`; everything else works |
| `NOTION_TOKEN` | pushing resources to Notion | the Notion buttons are disabled |
| `NOTION_RESOURCES_DB_ID` | which database to push into | same |
| `ANTHROPIC_API_KEY` | the OCR fallback for low-confidence / non-Latin frames | Vision's result is kept as-is |

The names match the user's Sky project exactly, so a `.env.local` there copies straight across.
The file is re-read on every lookup, so a key added while the app is running works without a
relaunch. Nothing in `SecretsStore` logs a value at any level — do not add logging that does.

**A dotfile is plaintext on disk.** The Keychain is the safer store and is still preferred when
a key is present there; the in-app key sheet writes to the Keychain only. `.env` exists purely
because it is faster to paste into.

The Notion database schema (verified against the real one) — Notion rejects the **whole** page
write on an unknown property, and the URL column is literally named `URL`:

| Property | Type | Written as |
| --- | --- | --- |
| `Name` | title | the resource name |
| `URL` | url | key omitted entirely when there is no URL — an empty string is rejected |
| `Status` | select | always `Saved` |
| `Category` | multi_select | subset of exactly ten options (`Resource.categories`) |
| `Description` | rich_text | one line, capped at 200 characters |

The ten categories: Claude Code, UI Components, Design Inspo, AI Tools, Dev Infrastructure,
SaaS/Biz, Learning, BI/Data, Tools, GitHub. They are the model's JSON-schema enum *and* are
re-filtered locally before the write.

---

## 8. Next steps, in order

Each has an acceptance criterion. Do not mark one done without meeting it.

### 1. ~~Verify the Groq extract path end-to-end~~ — **done 2026-09-13**

One real TikTok video (`tiktok-7667767850118991135`) produced:

```
resource   Emil Kowalski/Skills [Claude Code] -
resource   DevSwarm [AI Tools, Dev Infrastructure] https://devswarm.ai
```

Both are things the post actually points at; the one with no visible URL correctly got `null`
rather than an invented one. A second run re-ran nothing and left `resources.json`
byte-identical, `pushedToNotion` still false.

`qwen/qwen3.6-27b` does take images and a `json_schema` in one request, and `ExtractStage.parse`
reads the envelope correctly — but **four request-body fields had to change first**, and each
failure masked the next. The working shape and the measurements are in `DESIGN_SPEC.md` under
"The verified request shape"; the three that will bite again are in §9.

### 2. Verify the Notion push, including the duplicate prompt

Put `NOTION_TOKEN` + `NOTION_RESOURCES_DB_ID` in `~/Neat/.env`.

Unverified: that the `url` / `contains` filter in `findByURL` matches real rows, and that a page
create with exactly these property names succeeds.

> **Accept when:** one push creates a real row with Name, URL, Status=Saved, Category and
> Description all populated; pushing the *same* URL again raises the Add anyway / Skip prompt
> rather than silently creating a second row; "Skip" marks the resource settled so it stops
> being offered. Note in `DESIGN_SPEC.md` whether `page_size: 25` without cursor-following was
> enough in practice.

### 3. Test a real slideshow (photo-mode) post

Never tested — no public `/@user/photo/<id>` post could be found. Both branches exist:
yt-dlp may return **image URLs in the info JSON**, or it may **render the slides into an mp4**.
The code detects both; neither has run.

> **Accept when:** one real photo-mode URL produces one frame per slide in `frames/`,
> `transcribe` is `skipped` (not `done`, not pending), and `onscreen` reads all of them. Say in
> `DESIGN_SPEC.md` which of the two yt-dlp behaviours you actually saw.

### 4. ~~Move the onscreen-skip guard into `OnscreenStage`~~ — **done**

`OnscreenStage` now skips itself on an empty `frames/`, guarded on
`platform == .threads && stages.fetch.done` so a Threads post whose fetch actually failed is
still a real failure. `runThreads` no longer writes another stage's state. Covered by
"a text-only Threads post skips instead of throwing" and "a Threads item with empty frames but
an incomplete fetch still throws".

### 5. Harvest the Threads saved list (`WKWebView`)

The only part of Threads still unbuilt. See §6 for the plan.

> **Accept when:** a *Sync saves* action returns post URLs from a logged-in session, those URLs
> go through the existing paste intake unchanged, and re-syncing adds nothing for posts already
> on disk.

### 6. ~~Verify the Anthropic OCR fallback~~ — **closed by decision, 2026-09-14**

Not being done. The owner does not want an `ANTHROPIC_API_KEY` in this project, so the fallback
stays dark and Vision's local read is the final answer for every frame. That is the behaviour
the no-key path already implements, and it degrades the way it should: a missing key is a
`notice` in the log, never a failure, and never loses the text Vision did recognise.

What this costs, so nobody rediscovers it as a bug: frames with stylised or non-Latin text come
out wrong rather than missing — this library's one item reads `EMI-KOWALSI-SKE` for "Emil
Kowalski". `onscreen.txt` is a best-effort channel, and the transcript and caption carry the
substance.

The code is finished and was fixed during this work (it reads `SecretsStore` now, so a key in
the environment or `.env` would work immediately). Reopen only if the owner asks.

---

## 9. Traps

Every one of these is a **silent failure or a misleading error** that already cost real time.
Read the relevant row before touching that area.

| Area | Trap | Symptom | What to do |
| --- | --- | --- | --- |
| ffmpeg | ffmpeg 9 removed `-vsync` | `Option not found` — names the wrong thing | Use `-fps_mode vfr` |
| ffmpeg | filter arguments take **no quotes** | the same `Option not found` | `select='gt(scene,0.3)'` is *shell* quoting and `Process` has no shell. Escape the comma: `select=gt(scene\,0.3),scale=1280:-2` |
| Foundation | `URL.appending(path:)` percent-encodes `%` | ffmpeg receives `frame-%2502d.jpg` and writes one absurdly named file | Build the output pattern as a plain `String`, never a URL path component — `FrameExtractor.outputPattern(in:)` |
| Subprocess | reading one pipe while the child fills the other | deadlock, **only on large outputs**, i.e. only in real use | `ProcessRunner` drains stdout and stderr concurrently. Keep it that way. |
| TikTok | extraction is genuinely intermittent | the same URL fails with `Unable to extract universal data for rehydration`, then succeeds seconds later | `FetchStage` retries yt-dlp **3× with 3s backoff inside the stage**, before the item spends one of its two real ledger attempts. Transient noise must not burn a permanent attempt. |
| Threads | inverted User-Agent | a browser UA returns an empty JS shell | Keep `ThreadsFetch.userAgent` non-browser |
| Threads | deleted/private posts answer **HTTP 200** | an empty folder that looks like success | Treat missing content, not the status code, as the signal |
| App icon | `icon.json` colors need **four** components | `Exception while running actool: … attempt to insert nil object` — names neither key nor reason | `display-p3:r,g,b,a`. Three components look fine and are not. Colors are strings: `<space>:<components>`, never JSON objects. |
| App icon | generated PNGs come back with a halo and a body at alpha 253 | grey fringe once Icon Composer adds its shadow | Clamp programmatically: alpha `< 40` → `0`, alpha `>= 245` → `255` |
| XcodeGen | `.icon` is a directory and gets expanded | Xcode 26 stops recognising the icon asset | `project.yml` sets `options.fileTypes.icon.file: true` |
| DMG | `create-dmg` styles the window with AppleScript, dead on Tahoe | DMG mounts with a blank window | Use `dmgbuild`, which writes `.DS_Store` directly |
| DMG | `dmgbuild <= 1.6.5` (newest on **PyPI**) writes a `pBBk` bookmark record; Finder 26.2+ then refuses to draw the background | still blank, with a correct-looking `.DS_Store` | Fixed in **1.6.7, git-only**, needs Python ≥ 3.10 — hence the auto-provisioned `.dmgvenv`. `Scripts/build-dmg.sh` detects a `pBBk`-writing install and rebuilds the venv. |
| DMG | background must be **exactly the window size at 72 DPI** | a 2× image renders quarter-size and reads as "missing" | `window_rect` is `(540, 380)`; match it |
| macOS | a fixed System Settings accent **overrides** `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` | app icons purple, every control system blue | State `Color.neatAccent` explicitly and apply `.tint`. Leave the **sidebar** selection fill alone — users expect their own accent there. |
| SwiftUI | a hand-rolled `ScrollView` + `LazyVStack` + `onTapGesture` queue | clicks do not reliably register | Use `List(selection:)`. See §10. |
| SPM | `argmaxinc/WhisperKit` no longer exists | package resolution fails | It is `argmaxinc/argmax-oss-swift` from 1.1.0 — link the `WhisperKit` product only, not the `ArgmaxOSS` umbrella (it drags in TTSKit and SpeakerKit) |
| Docs | Apple's documentation pages are JS-rendered | a fetcher gets nothing back | Read the installed SDK's `.swiftinterface`. Verified Liquid Glass signatures are already recorded in `DESIGN_SPEC.md` — use those. |
| Groq | an image costs a **flat** 783 prompt tokens at 768px, 512px and 256px alike | downscaling to escape a token limit returns a **byte-identical** rejection, so it reads as "the change didn't apply" | Only `maxImages` moves token cost. `maxDimension` buys upload bytes and nothing else. |
| Groq | the rate limiter estimates an image at ~2,048 tokens, not what the tokenizer charges | 3 frames is `Requested 7683` against a 7,000 ITPM cap, while the 2-frame request that passes reports **2,610** actual tokens | Free tier fits 2 frames. Raise `maxImages` to 3 only on a paid tier. |
| Groq | no `max_tokens` means Groq assumes the model's 1,484 default | **429 before the request runs** — OTPM limit 1,000, "Requested 1484" | Always send `max_tokens`. |
| Groq | `retry-after` is sent on a **413** too, where waiting can never help — observed alongside `x-ratelimit-remaining-tokens: 8000`, i.e. the full allowance free | a retry loop that trusts the header retries a request that can never fit, forever | Only wait on a **429**. `ExtractStage.send` treats 413 as a real failure and names `maxImages` in the message. |
| Groq | `qwen/qwen3.6-27b` reasons by default and eats the whole output budget | HTTP 400 `json_validate_failed` with an **empty** `failed_generation` — reads like a schema bug, is not | `reasoning_effort: "none"`, supported by exactly this model. Observed 681 reasoning tokens on a trivial prompt. |
| WhisperKit | the first transcribe on a machine sits in ANECompiler | minutes at **0% CPU** with 620MB resident — indistinguishable from a hang | It is compiling the model for the Neural Engine. Wait. `sample <pid>` shows `MLModel loadContentsOfURL:` if you need to confirm. |

---

## 10. Non-negotiables

These are not style preferences. Each one exists because breaking it already caused damage.

**Never overwrite.** If a file exists, read it and propose a diff. Applies to every source file
and to `CLAUDE.md`, `README.md`, `DESIGN_SPEC.md`, `project.yml`. Assume anything on disk was
hand-edited; your job is to merge.

**Idempotent.** Every stage must be safe to re-run and must check `needsRun` before doing work.
Writes are atomic — temp file plus rename, never truncate-and-write.

**The folder on disk wins over the ledger.** If `item.json` says a stage is done, believe it.
The ledger is a cache of intent, not the truth.

**`skipped` ≠ `done`.** `skipped` means the stage does not apply and must never be retried.

**Never claim a UI task is done without having looked at a screenshot of it.** Take it with
`make shot`, open it, list what is wrong, fix it, repeat. Reading the code does not count.

**System components first.** Standard SwiftUI controls adopt Liquid Glass automatically on the
macOS 26 SDK. `.glassEffect` is applied by hand in exactly **two** places — the drop well and
the queue rows. No hand-rolled toolbars, no `.ultraThinMaterial` stand-ins, no decorative
shadows or borders, never glass stacked on glass. If you are writing custom chrome, stop and
ask first.

**The queue stays a real `List(selection:)`.** It was a `ScrollView` + `LazyVStack` +
`onTapGesture` and clicks did not reliably register. A real `List` gives single-click select,
double-click via `.contextMenu(forSelectionType:menu:primaryAction:)`, arrow keys, type-select,
shift/command multi-select, Delete via `.onDeleteCommand`, and VoiceOver. A tap gesture throws
all seven away. It looks like the simpler option in the file. It is not. Rows are
`.draggable(row.folder)` so an item's folder drags straight into Finder.

**Local only.** No accounts, no database. State is JSON files under `~/Neat/`. The only network
calls are fetching media, the Threads embed page, and the three optional APIs above.

**Read the docs, not your memory,** for anything Liquid Glass or Apple-API shaped — those APIs
are new enough to hallucinate confidently.
