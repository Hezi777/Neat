# Neat — Design Spec

Decisions, verified API details, and the things a future session would otherwise
have to rediscover. `CLAUDE.md` holds the rules; this file holds the reasoning.

## Build order

Stop at each milestone and show what runs.

| | Milestone | Done when |
| --- | --- | --- |
| ✅ | **M0** | `project.yml`, module skeletons, docs, app launches to an empty window |
| ✅ | **M1** | Canonical ID + tests, ledger read/write, paste parsing, new/have/unavailable summary. No downloading. |
| ✅ | **M2** | fetch stage, type detection, real folders, resume after a forced quit. Video verified end-to-end against a real post; the slideshow path is written but **not** verified. |
| ✅ | **M3** | transcribe stage, including `skipped` for items with no speech. Verified: 1218 accurate characters off a real video. |
| ✅ | **M4** | onscreen stage across all three types, including the API fallback. Vision verified on real frames; the API fallback is unit-tested only. |
| ✅ | **M5** | UI pass. Three-column `NavigationSplitView`, one spacing scale, glass on the drop well and rows only, light/dark both checked from screenshots. |

Shipped after M5, in order:

| | What | State |
| --- | --- | --- |
| ✅ | **Threads, for real** | Per-post fetch via the public embed page. Verified end-to-end against three real public posts. Harvesting the *saved list* is still unbuilt. |
| ✅ | **`extract` stage** | Fourth stage, Groq, writes `resources.json`. **Verified against the live API 2026-09-13** — see "The verified request shape". |
| ✅ | **Notion push** | `NotionClient`, URL-normalized dedupe, Finder-style duplicate prompt. **Never run against a real database.** |
| ✅ | **Secrets** | `SecretsStore`: environment → `~/Neat/.env` → Keychain. `.env.example` is the template. |
| ✅ | **Installer DMG** | `make dmg`. Verified: builds, mounts, Finder draws the background with both icons placed. |

151 tests across 28 suites, all passing (`make test`).

### Not verified yet

Two things are implemented and believed correct but have never been run for real. Do not
describe either as done.

| What | Why not | What would settle it |
| --- | --- | --- |
| slideshow fetch | No public photo-mode post could be found to test against. Both branches exist — slide image URLs in the info JSON, and yt-dlp rendering the slides into an mp4. | One real `/@user/photo/<id>` URL. |
| Anthropic OCR fallback | Unit-tested for request shape, downscaling and failure handling, but never sent to `api.anthropic.com`. | One run with a key in Keychain against a Hebrew frame. |
| ~~Groq `extract` stage~~ | **Done 2026-09-13.** Images + `json_schema` in one request: confirmed. Envelope: confirmed, no parser change. Took four request-body changes to get there — see "The verified request shape". | — |
| Notion push | No token was available. Unverified: that the `url`/`contains` filter matches real rows, and that a page create with these exact property names succeeds. | One token plus the database id, then one real push and one deliberate duplicate. |
| `NotionClient.findByURL` paging | Pages once at `page_size: 25` and never follows `next_cursor`. A resource with more than 25 loosely-matching rows could miss a duplicate. | Either paging, or a decision that 25 is enough. |

Consolidation passes with the Codex plugin after **M2** and **M5**: hand it the diff and ask
for duplicated logic, dead code, inconsistent naming, stage functions that leaked UI or
filesystem assumptions into `NeatCore`, and error paths that swallow failures. Bring findings
back and agree or disagree explicitly — never apply blind.

## Environment (verified 2026-09-12)

macOS 26.6, Xcode 26.6, Swift 6.3.3, SDK macOS 26.5. `xcodegen`, `make` present.
`yt-dlp` 2026.08.19 and **ffmpeg 9.0.1** are installed via Homebrew — the ffmpeg major
version matters, see the traps below. `yt-dlp` was absent when M0 was written, which was
convenient for testing the preflight sheet.

`swift-tools-version: 6.2` with `.macOS(.v26)` compiles on this toolchain (verified, not assumed).

## Subprocess traps (M2, all hit for real)

Every one of these cost an hour and none of them announce themselves clearly. They are
recorded because the error messages actively mislead.

| Trap | Symptom | Fix |
| --- | --- | --- |
| `URL.appending(path:)` percent-encodes `%` | ffmpeg receives `frame-%2502d.jpg` and writes one absurdly named file | Build the output pattern as a plain `String`, never as a `URL` path component — `FrameExtractor.outputPattern(in:)` |
| Single quotes in an ffmpeg filter | `Error splitting the argument list: Option not found` | `select='gt(scene,0.3)'` is **shell** quoting. `Process` has no shell, so the quotes arrive literally. Escape the comma instead: `select=gt(scene\,0.3),scale=1280:-2` |
| `-vsync` | the same misleading `Option not found` | **ffmpeg 9 removed `-vsync` outright.** It is `-fps_mode vfr` now. Verified against ffmpeg 9.0.1 on this machine. |

`ProcessRunner` drains stdout and stderr **concurrently**. A child that fills a pipe buffer
while the parent is blocked reading the other pipe deadlocks, and it deadlocks only on the
large outputs — which is to say, only in real use. Errors carry the tool's own stderr,
because yt-dlp's own message is always more informative than anything wrapped around it.

**TikTok extraction is genuinely flaky.** The same URL fails with `Unable to extract
universal data for rehydration` and then succeeds seconds later, repeatedly, with no change
in input. `FetchStage` therefore retries yt-dlp **3× with a 3s backoff inside the stage**,
before the item spends one of its two real ledger attempts. Transient network noise must not
burn a permanent attempt.

Raw yt-dlp output is saved verbatim as `info.json` next to `item.json`. Its schema moves
between releases, so `MediaInfo` decodes leniently and the untouched payload stays on disk
for whatever the decoder missed.

## Running the pipeline headlessly

`neat-cli` is an executable target in the package — a thin harness that runs intake plus the
whole pipeline against a throwaway root, with no window:

```bash
cd Packages/NeatKit && swift build
.build/debug/neat-cli /tmp/neat-scratch "https://www.tiktok.com/@user/video/123"
```

It prints the paste summary, each state transition, and the final stage state per item. This
is how the stages were verified against real posts — far faster than launching the app, and
it never touches `~/Neat/`.

## Sources are separate lists, not one queue

### TikTok collection intake — added 2026-09-12

The user identified Clipmine as the predecessor whose collection support Neat must replace.
Its architecture and limitations are preserved in `CLIPMINE_HANDOFF.md`; the old project
has been removed. No records or saved source list existed in its data directory to migrate.

`SourceAdapter.resolvedURL(for:)` resolves a TikTok share link before intake decides whether
it names one post or a collection. `TikTokURL.isCollection` keeps a collection ID out of
post identity. `TikTokCollection` runs the existing yt-dlp tool in flat-playlist mode with
Chrome cookies, a bounded timeout, modest retries, and request spacing. This adds no package
dependency and performs no media downloads during listing.

Collection members flow through ordinary `PasteIntake` classification: preserve listing
order, dedupe across collections and individually pasted links, honor on-disk items and
dead/skipped ledger markers, and persist the member's post URL. Listing failures are shown
in the UI. Malformed entries, unsuccessful process exits, and repeated IDs reject a listing
instead of silently turning a partial result into a successful import. This detects known
truncation signals; it cannot prove that TikTok never omits unique members server-side.

Live verification: the user's short link resolved to the AI collection, and Neat imported
77 unique posts into a temporary library. Reimport plus an overlapping individual link
returned 0 new / 77 already have. `neat-cli <root> --intake-only <url>` exercises this path
without downloading a collection's media. Remembering collection URLs as persistent sources
and Clipmine's adaptive cooldown policy are documented follow-up behaviors, not included in
this collection-link fix.

`NeatUI/AppModel.swift` defines `Source`: TikTok and Threads (both live), Instagram / YouTube
/ Reddit named as greyed-out planned entries, and `Source.resources` — a Library entry that is
not a platform at all but the cross-cutting view of everything `extract` found. The window has
a sidebar of sources and `visibleRows` filters the queue by the selected platform.

**This is not the organizing that Neat excludes, and the distinction matters enough to write
down.** Organizing means deciding what a post is *about* — tags, taxonomy, renaming, search.
That stays in the separate Claude Code session, permanently. Separating sources is only
saying where an item came from, which the canonical ID already encodes (`tiktok-…`,
`threads-…`); the sidebar just stops two unlike kinds of material sharing one unreadable
list. A future session looking at this will think it is scope creep — it is not, and the
test is simple: if a feature needs to read the *content* of an item to work, it does not
belong here.

## Liquid Glass — verified signatures

Apple's documentation pages are JS-rendered and return nothing to a fetcher. These came from
the installed SDK's `SwiftUICore.swiftinterface`, so they are exact. Do not trust a
remembered shape for these — they are new enough to hallucinate confidently.

```swift
// @available(iOS 26.0, macOS 26.0, *) — visionOS unavailable
func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View
func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> some View
func glassEffectTransition(_ transition: GlassEffectTransition) -> some View

struct GlassEffectContainer<Content: View>: View {
    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content)
}

struct Glass: Equatable, Sendable {
    static var regular: Glass; static var clear: Glass; static var identity: Glass
    func tint(_ color: Color?) -> Glass
    func interactive(_ isEnabled: Bool = true) -> Glass
}
```

`Glass` and the effect modifiers live in **SwiftUICore**; the glass *button styles*
(`.buttonStyle(.glass)`, `.glassProminent`) live in **SwiftUI**. `import SwiftUI` re-exports both.

Apply `.glassEffect` by hand in exactly two places: the drop well and the queue rows.
Everywhere else use the standard control and let the macOS 26 SDK apply the material. Read
Apple's *Landmarks: Building an app with Liquid Glass* sample before writing views — it is
real compiling code and worth more than a mockup.

## App icon

The icon is a full-colour illustration, not a flat symbol: a navy→purple gradient folder with
three white cards rising out of it, each carrying a real platform mark — TikTok, Threads,
YouTube. It says what the app does — saved posts from several services become a folder — in
one picture.

### How it was made

| Step | Tool | Why |
| --- | --- | --- |
| Base illustration | Codex CLI's built-in `image_gen` | Generates the folder, cards, gradient and lighting |
| Brand marks | `simple-icons` SVGs, rasterised with ImageMagick, composited in at exact positions | Models render real logos distorted — near-miss glyphs, wrong proportions. Never ask the model to draw a logo. |
| Alpha cleanup | a small script, not an image editor | The generated PNG comes back unclean — see below |
| Assembly | Icon Composer, PNG layer in `App/AppIcon.icon` | Icon Composer accepts PNG layers, not only SVG |

**Alpha cleanup, and expect to need it again with any generated art.** The returned PNG had
a soft halo around the silhouette and a body sitting at alpha 253 rather than 255. Fix it
programmatically, not by eye:

- alpha `< 40` → `0` — kills the halo
- alpha `>= 245` → `255` — snaps the body fully opaque

Leaving either in place shows up as a grey fringe once Icon Composer applies its own shadow.

The background `fill` is a light neutral gradient so the navy folder reads against it — that
is the inverse of the usual advice, and it is correct here because the artwork itself carries
the colour.

### Generating art with Codex

Codex CLI 0.153.4, logged in via ChatGPT — **no `OPENAI_API_KEY` needed** for the built-in
path. The skill lives at `~/.codex/skills/.system/imagegen`.

```bash
codex exec --sandbox workspace-write --skip-git-repo-check "<brief>"
```

Note it is `--sandbox workspace-write`, not `--full-auto` (that flag was removed). Codex
saves to `$CODEX_HOME/generated_images/` and copies into the working directory, so always
state the destination filename in the brief.

The skill's own prompt structure gets much better results than a one-liner:

```
Use case:             logo-brand / app icon symbol
Primary request:      <what the mark is>
Style/medium:         <flat vector / dimensional illustration>
Composition/framing:  centered, square canvas, generous margin
Constraints:          readable at 16px; no text; no watermark; no logos
```

Ask explicitly for a **genuinely transparent background** (the built-in tool supports alpha;
the CLI-fallback `gpt-image-2` does not), and generate **only the artwork** — never a
finished rounded square. Icon Composer supplies the tile shape, gradient, specular highlight
and shadow; a generated tile fights all four. Iterate with small single-change edits,
restating the invariants each time, rather than rewriting the brief.

**Trademark position.** The icon carries third-party marks. The user was told that
AI-assisted use of real logos is a trademark risk and explicitly accepted it, on the grounds
that Neat is local-only and not distributed. If that ever changes, the marks come out first.

### Assembling in Icon Composer

Icon Composer 1.6 ships inside Xcode at
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`.

A `.icon` is a **package — a directory** containing `icon.json` plus an `Assets/` folder, so
it is inspectable and diffable in git. It carries a background plus up to four foreground
layers, each with its own material, opacity, shadow and glass settings, rendered across four
appearance modes (Default, Dark, Clear, Tinted).

### icon.json schema (reverse-engineered, verified by build)

Apple does not publish this and no example was findable, so it was recovered from strings in
`IconComposerFoundation.framework` and confirmed by building until `actool` accepted it.
`App/AppIcon.icon/icon.json` is the working result:

```json
{
  "fill" : { "linear-gradient" : [ "display-p3:0.980,0.980,0.992,1.0",
                                   "display-p3:0.870,0.878,0.921,1.0" ] },
  "groups" : [
    { "layers" : [ { "image-name" : "neat-logo.png", "name" : "Folder" } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
      "specular" : true,
      "translucency" : { "enabled" : false, "value" : 0.5 } }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
```

The part that costs an afternoon if you do not know it: **colors are strings encoded as
`<color-space>:<components>`** — `display-p3:r,g,b,a`, or `named:system-teal`. Passing a
JSON object for a color fails with a bare
`Exception while running actool: ... attempt to insert nil object`, which names neither the
key nor the reason. Valid color spaces: `srgb`, `extended-srgb`, `display-p3`, `gray`,
`extended-gray`, `named`. A fill must be exactly one of `solid`, `linear-gradient`
(exactly two colors) or `automatic-gradient`.

The second half of the same trap: **a color string needs four comma-separated components,
including alpha.** `display-p3:0.98,0.98,0.99` fails with exactly the same opaque
`attempt to insert nil object`; `display-p3:0.98,0.98,0.99,1.0` works. Three components look
obviously fine and are not.

Top-level `fill` is the **background**. A white template layer gets tinted per appearance by
the system; the current full-colour PNG layer is not tinted, which is why the background
gradient is a light neutral rather than a strong colour. Verified from the built product,
not assumed.

**XcodeGen gotcha:** XcodeGen treats `.icon` as a folder by default and expands it into
loose files, at which point Xcode 26 stops recognising it as an icon asset. `project.yml`
therefore sets:

```yaml
options:
  fileTypes:
    icon:
      file: true
```

Then point `ASSETCATALOG_COMPILER_APPICON_NAME` at the filename without its extension.

## Screenshot tooling

XcodeBuildMCP ships **no macOS window screenshot tool at any workflow setting** — its
`screenshot` tool shells out to `simctl` and is simulator-only. So `Scripts/shot.sh` finds
the window via `CGWindowListCopyWindowInfo` (largest on-screen window at layer 0 owned by
`Neat`) and hands the id to `screencapture -l`. It exits nonzero when no window is found, so
a failed screenshot can never pass silently as a green milestone.

`.mcp.json` sets `XCODEBUILDMCP_ENABLED_WORKFLOWS` to include `macos`, which is what provides
`build_macos`, `build_run_macos` and `launch_mac_app`. Changing that file needs a Claude Code
restart to take effect.

## Dependencies

Only two third-party dependencies are permitted without asking first.

**WhisperKit** — added at M3. **The package moved:** `argmaxinc/WhisperKit` no longer
exists. It now ships inside Argmax's umbrella repo:

```swift
.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
// link the WhisperKit product only — not the ArgmaxOSS umbrella, which drags in
// TTSKit and SpeakerKit, neither of which this app wants.
.product(name: "WhisperKit", package: "argmax-oss-swift")
```

The model is `large-v3-v20240930_turbo_632MB` (`TranscribeStage.modelName`), verified present
in `argmaxinc/whisperkit-coreml` on HuggingFace and downloaded once on first use. Slideshow
and image items are marked `skipped`, never `done`, so the resume sweep stops retrying a
thing that will never have speech.

**There is no official Anthropic SDK for Swift.** `AnthropicOCR` therefore speaks raw HTTP to
`/v1/messages`. Model `claude-sonnet-4-6` — the one named in the original brief;
`claude-sonnet-5` is newer and cheaper if there is ever a reason to switch. Frames are
downscaled to 768px before upload, and the key lives in Keychain via `KeychainStore`, never
in a file. A failed API call keeps whatever Vision already read rather than throwing the
partial result away.

**Hugeicons** — there is **no official Hugeicons Swift package**; only unofficial
third-party wrappers (e.g. `iSapozhnik/hugeicons-swift`, free icons only). So the fallback
applies: pull the SVGs, generate an asset catalog of template images, and expose them through
a typed `NeatIcon` enum so call sites stay clean. Stroke style, one consistent weight, and no
SF Symbols mixed in.

## Type routing

The stages are identical for every type. Only how `frames/` gets populated changes.

- **video** — `ffmpeg` scene detection, capped at 8 keyframes, forcing one every 3s if fewer
  than 3 are found. The filter is written `select=gt(scene\,0.3),scale=1280:-2` — unquoted,
  comma escaped; see the subprocess traps above before touching it.
- **slideshow** — every slide is a frame; no `ffmpeg`, no cap. **yt-dlp's photo-mode handling
  is inconsistent between releases:** it may return image URLs in the info JSON, or it may
  render the slides into an mp4. Detect both. Given an mp4 of a slideshow, extract one frame
  per slide transition rather than by scene score; given neither, fall back to pulling image
  URLs straight from the info JSON. These posts are common in tech content — a whole tutorial
  across six slides — so losing them loses a lot.
- **image** — download *every* image in the post, not just the first.

For `slideshow` and `image` the audio is absent or is music carrying no information, so mark
transcribe `skipped` rather than leaving it undone.

## The `extract` stage

The fourth stage. It reads everything the pipeline already produced for an item and writes
`resources.json` — the re-findable things the post pointed at.

    ~/Neat/items/<id>/resources.json
    {"v": 1, "resources": [{ id, name, url, category, summary, pushedToNotion }]}

`StageVersions.extract = 1`, `Stages.extract`, `NeatPaths.resources(_:)`. `Stages` has a
hand-written `init(from:)` purely so that a missing `extract` key in an `item.json` written
before the stage existed decodes as "not run yet" instead of failing the whole item.

### Why this model

`ExtractStage.model = "qwen/qwen3.6-27b"` on Groq, via the OpenAI-compatible
`/openai/v1/chat/completions` endpoint (there is no official Groq SDK for Swift). It was
chosen because it does **vision and JSON-schema structured output with constrained decoding
in the same request** — most models do one or the other, and doing both is what lets the
category list be an enum the model cannot escape.

**Groq serves it as a preview model.** Expect it to be withdrawn or renamed. It lives in one
constant so the swap is one line, and `ExtractStage.parse` reads the ordinary OpenAI envelope,
so a different OpenAI-compatible model should drop in.

### What it sends

Text: caption + `body.txt` + `transcript.txt` + `onscreen.txt`, whichever exist.

Images: up to **2** frames (`maxImages`), **evenly spread** rather than the first two,
downscaled to 512px. The spread matters — in a six-slide tutorial the recommendation is on the
last slide. Sending frames is the point, not a bonus: OCR reliably misses a tool name inside a
terminal screenshot, a URL in a small caption, or a logo with no text at all. This is how
slideshows, Threads posts and static images get read at all.

### The verified request shape — 2026-09-13

First live run. Four fields had to change before the API would answer at all; each failure
masked the next, so they only surfaced one at a time.

| Field | Was | Is | Why |
| --- | --- | --- | --- |
| `maxImages` | 5 | **2** | The *model* takes 3 ("Too many images provided. This model supports up to 3 images"). The free tier takes 2 — see below. |
| `maxDimension` | 768 | **512** | Halves upload bytes. **Buys no tokens** — see below. |
| `max_tokens` | absent | **900** | Absent, Groq assumes the model's 1,484-token default, compares it to the account's 1,000 OTPM allowance and returns **429 before running the request**. |
| `reasoning_effort` | absent | **"none"** | This is a reasoning model. It spent **681 output tokens** thinking on a trivial prompt, leaving nothing for the JSON: HTTP 400 `json_validate_failed` with an empty `failed_generation`. `"none"` is supported by exactly this model. |

**An image costs a flat 783 prompt tokens at 768px, 512px and 256px alike.** Measured against
the live API on the same frame. Resolution changes the bytes on the wire and nothing else, so
`maxDimension` is not a lever for token cost — only `maxImages` is. Do not "fix" an ITPM
rejection by downscaling; it produces a byte-identical rejection.

**Groq's rate limiter does not use the tokenizer's count.** It estimates an image at roughly
2,048 input tokens, so three frames plus this pipeline's text is rejected as
`Requested 7683` against a 7,000 ITPM allowance — while the same two-frame request that *is*
allowed reports **2,610** actual prompt tokens, under half the cap. Three frames is therefore
unreachable on the free tier at any resolution. Raise `maxImages` to 3 on a paid tier.

Confirmed working: vision **and** `json_schema` in one request, `strict: true`, categories as a
schema enum. `ExtractStage.parse` reads the envelope correctly — `choices[0].message.content`
holding a JSON document keyed `resources`. No parser change was needed.

### Three behaviours that are deliberate

- **No Groq key → `.skipped`, not a failure.** Extraction sits on top of a pipeline that
  already works; a missing key must not make items look broken.
- **An empty array is a correct answer** and is written to disk. Most posts recommend nothing,
  and writing the empty result is what stops the stage re-running forever looking for one.
- **Re-extraction merges.** `ResourcesFile.merge` carries `pushedToNotion` across, and keeps
  an already-pushed resource the model no longer returns — its Notion row still exists.
  Anything else that vanished is dropped.

`Resource.make` is the only constructor: it normalizes the URL, drops any category outside the
ten, trims the summary to 200 characters, and derives a stable `id` (the normalized URL
lowercased, or a slug of the name when there is no URL).

## Notion push

`NotionClient` — raw HTTP against `api.notion.com/v1`, same shape as `AnthropicOCR`, because
there is no official Notion SDK for Swift. `Notion-Version: 2022-06-28` is pinned behaviour,
not a "latest" alias.

### The real database schema

Verified against the user's own Resources database. Notion rejects the **whole** page write on
an unknown property, and the URL column is literally named `URL`, not `Url`.

| Property | Type | Written as |
| --- | --- | --- |
| `Name` | title | the resource name |
| `URL` | url | omitted entirely when there is no URL — Notion rejects an empty string |
| `Status` | select | always `Saved`. "Reading"/"Using" are moved by hand afterwards. |
| `Category` | multi_select | a subset of exactly ten options, below |
| `Description` | rich_text | the one-line summary, capped at 200 characters |

The ten categories, in `Resource.categories`: Claude Code, UI Components, Design Inspo, AI
Tools, Dev Infrastructure, SaaS/Biz, Learning, BI/Data, Tools, GitHub. They are the model's
JSON-schema enum *and* re-filtered locally in `sanitizedCategories` before the write. An
invented category fails the Notion write; a guessed one is worse than none.

### Dedupe

`ResourceURL` is **one** normalizer used for both the resource id and the Notion dedupe key.
If those two disagreed by so much as a trailing slash, the same tool would land in Notion
twice. It lowercases the host, strips `www.`, drops the fragment, drops `utm_*` plus
`fbclid`/`igshid`/`si`/`ref`/`ref_src`, and strips every trailing slash. **The path keeps its
case** — hosts are case-insensitive, paths are not, and lowercasing a GitHub repo path breaks
the link.

Notion stores whatever was originally pasted, and its `url` filter has no scheme-tolerant
equality, so `findByURL` narrows with `contains` on the scheme-less form and does the real
comparison locally with `sameResource`. It pages **once** at `page_size: 25` and does not
follow the cursor — see the unverified table.

A match raises a Finder-style prompt: **Add anyway / Skip**. `DuplicateDecision.replace`
deliberately throws `notImplemented` — overwriting a row someone may have edited by hand in
Notion is a decision, not a default.

## Secrets

`SecretsStore` resolves each key in this order, first hit wins:

1. the process environment — so a terminal `neat-cli` run can override the app
2. `~/Neat/.env`
3. the Keychain (Anthropic only — it is the only key that was ever stored there)

Keys: `GROQ_API_KEY`, `NOTION_TOKEN`, `NOTION_RESOURCES_DB_ID`, `ANTHROPIC_API_KEY`. **The
names match the user's Sky project exactly**, so a `.env.local` there can be copy-pasted.
`.env.example` at the repo root is the template; copy it to `~/Neat/.env`.

The file is re-read on every lookup rather than cached — it is tiny, and a key added while the
app is running should work without a relaunch. The parser is deliberately forgiving (CRLF,
comments, `export` prefixes, quotes, `=` inside values) and ignores anything it cannot parse:
a malformed line must not stop the app from starting.

**The honest tradeoff:** a dotfile is plaintext on disk. The Keychain is safer and is still
preferred when a key is present there, and the in-app key sheet writes to the Keychain only.
`.env` exists because it is faster to paste into. Nothing in `SecretsStore` logs a value, at
any level, and no caller should either.

## Threads — implemented, via the public embed page

There is **no yt-dlp extractor for Threads**, so this is Neat's own acquisition path. Two
separate problems, and only one of them is solved:

| Problem | State |
| --- | --- |
| Fetch one post, given its URL | **Solved.** Public embed page, no login, no browser. |
| Harvest *your saved list* | **Not built.** Still needs the `WKWebView` plan below. |

### Fetching one post

`https://www.threads.com/t/<shortcode>/embed/` is the one Threads surface that is rendered
server-side. The post page itself ships an empty SPA shell.

**The User-Agent behaviour is inverted, and this is the detail that costs an afternoon.** A
*browser* User-Agent gets the empty JS shell back; a plain, non-browser one gets the fully
rendered HTML. That is the opposite of the usual scraping advice, so `ThreadsFetch.userAgent`
is deliberately `Neat/1.0 (+local archiver)` and must stay that way. There is no login wall
on this path.

The `@username` segment is decorative — the server ignores it — so `ThreadsURL.embedURL` is
built from the **shortcode alone**. A stored URL whose account has since been renamed still
resolves.

| File | Module | Does |
| --- | --- | --- |
| `ThreadsURL.swift` | NeatAdapters | Pure parser. Accepts `threads.net` and `threads.com`, `/@user/post/CODE` and `/t/CODE`. The shortcode is the canonical native ID, so all four forms key to one folder. |
| `ThreadsEmbed.swift` | NeatAdapters | Pure HTML parser, no network: body text plus attachment image URLs. Tested against saved HTML. |
| `ThreadsFetch.swift` | NeatPipeline | The one network call, plus `FetchStage.runThreads`. |

Output: the post body goes to `body.txt` as a first-class channel next to `onscreen.txt`;
attachments go to `frames/` through the existing `FrameExtractor`, with the same
`frame-00.jpg` naming as every other type, so nothing downstream branches on source. The item
type is `.image`, which is what makes `transcribe` mark itself `skipped` rather than hunting
for speech. Attachments are the payload, not a bonus — Threads posts routinely carry
screenshots of code or terminal output.

A deleted or private post answers **HTTP 200 with a shell**, so `ThreadsEmbed.parse` throws
`postUnavailable` when it finds neither text nor images. Status code alone would lie.

### Known wart: `FetchStage` writes `onscreen`'s state

For a text-only Threads post there are no frames, and `OnscreenStage` throws on an empty
`frames/` — so the item would retry forever and eventually die. `runThreads` therefore sets
`item.stages.onscreen = .skippedStage(...)` itself. One stage writing another stage's state
is a reach, and the cleaner home is a `platform == .threads` (or "no frames") guard inside
`OnscreenStage`. Flagged as a cleanup, not a bug — the behaviour is correct today.

### Harvesting the saved list — still the plan

Unchanged and still unbuilt: a persistent `WKWebView` logged into once, with a **Sync saves**
button that auto-scrolls the saved tab and harvests post URLs via `evaluateJavaScript`. Only
the *per-post* fetch escaped needing a browser; the saved list is behind auth and is not
server-rendered anywhere.

## M5 UI loop

Repeat until it passes, screenshotting each round: build, launch, capture the empty state, a
queue mid-run and a finished queue; list what is actually wrong; fix the top three; repeat.

**Light first, with an explicit dark toggle.** `Appearance` in `NeatUI/Theme.swift` is the
one switch; the app does not follow the system appearance. This is a stated user preference,
not an oversight — but it does not relax the pass criteria below, which still require the
window to hold up in *both* schemes.

Pass criteria, all verified from a screenshot rather than from the code:

- Spacing comes from one small fixed scale, used everywhere.
- Every icon shares stroke weight and optical size.
- Glass appears on the drop well and rows only — never glass on glass.
- Row state is legible at a glance without reading the label.
- Nothing clips or overlaps at the minimum window size.
- It holds up in light and dark, and with Reduce Transparency on.

## Two UI findings worth not re-deciding

### The queue is a real `List`, and must stay one

It was a `ScrollView` + `LazyVStack` + `onTapGesture`, and clicks did not reliably register.
`List(selection:)` fixed that, and the reason to record it is that a hand-rolled stack looks
like the *simpler* option to anyone reading the file later. It is not. A real `List` gives,
for free:

single-click select · double-click via `.contextMenu(forSelectionType:menu:primaryAction:)` ·
arrow-key navigation · type-select · shift/command multi-select · Delete through
`.onDeleteCommand` · VoiceOver

A tap gesture throws away all seven. Do not "simplify" it back. Rows are `.draggable(row.folder)`
so an item's folder can be dragged straight into Finder.

### The accent colour has to be stated twice

The app ships `App/Assets.xcassets/AccentColor` and sets
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, and that is still correct — but **macOS only
honours it when the user's System Settings accent is set to "Multicolor".** A fixed system
accent wins, which left the app's own icons purple and every control blue. So `Color.neatAccent`
is stated explicitly in `Theme.swift` and applied with `.tint`.

The macOS **sidebar** selection fill still follows the system accent, and is deliberately left
alone: users expect their own accent in a sidebar, and overriding it there reads as a bug.

The window is a three-column `NavigationSplitView` — source sidebar, queue, resource inspector.
The sidebar has Sources (TikTok, Threads), Library (Resources, which cuts across sources) and a
greyed-out "Coming soon" section. Light by default with a dark toggle, stored in
`@AppStorage("appearance")`.

## Packaging — the installer DMG

`make dmg` → `Scripts/build-dmg.sh` + `Scripts/dmgbuild-settings.py` + `Assets/dmg/background.png`,
output to `release/<MARKETING_VERSION>/Neat-<version>.dmg`.

**Three macOS 26 traps, every one a silent failure** — the DMG builds and mounts and simply
looks blank:

| Trap | Symptom | Fix |
| --- | --- | --- |
| `create-dmg` styles the window with **AppleScript**, which no longer works on Tahoe | background file is copied in but nothing references it; blank window | Use `dmgbuild`, which writes `.DS_Store` directly |
| `dmgbuild <= 1.6.5` (the newest on **PyPI**) writes a `pBBk` bookmark record, and Finder 26.2+ refuses to draw the background when it is present | still blank, with a correct-looking `.DS_Store` | The fix is in **1.6.7, git-only**, which needs Python ≥ 3.10 — hence the auto-provisioned `.dmgvenv`. The script detects a `pBBk`-writing install and rebuilds the venv. |
| The background must be **exactly the window size at 72 DPI** | a 2× image renders quarter-size and reads as "missing" | `window_rect` is `(540, 380)`; the PNG matches at 72 DPI |

Verified: builds, mounts, and Finder renders the background with both icons correctly placed.
The background art was generated with the Codex CLI's `image_gen` (same path as the app icon)
and composed so the two 88px icon zones stay empty.

## Rejected

- **Notion integration — reversed, deliberately, by the user.** This was listed here as
  permanently out of scope. It is now built (`ExtractStage` + `NotionClient`). The boundary
  was revisited on purpose, not forgotten, and the reasoning is narrower than it looks: the
  extract stage records only what a post *points at* — a tool, a repo, a URL that was visibly
  on screen — and the push is a per-resource button the user presses. Neither decides what a
  post is *about*. Tagging, taxonomy, renaming and search stay out, and stay with the separate
  Claude Code session. If a future feature needs to judge a post's subject, it is over the
  line again.
- **Search UI, tagging, editing, a second window** — still out. The organizing layer is a
  separate Claude Code session reading the folders.
- **Bundling `yt-dlp`/`ffmpeg`** — code-signing cost not worth paying in v1; resolved from
  `PATH` with a preflight check instead. This is also why the app is not sandboxed.
- **A settings window** — the API key sheet and the preflight sheet are enough.
- **A logging framework** — `os.Logger`, one subsystem (`com.hen.neat`).
- **Any abstraction for "future platforms"** beyond `SourceAdapter`.
