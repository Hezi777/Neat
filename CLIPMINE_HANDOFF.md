# Clipmine architecture preserved for Neat

Inspected 2026-09-12 before the user-requested removal of
`/Users/hen/Developer/archive/clipmine`. This preserves useful behavior and known
limitations from its source; it does not claim that every behavior has been ported
to Neat. Neat's implementation progress belongs in `PLAN.md`.

## System shape

Clipmine was a local TikTok collection scraper: React/Vite frontend → Python
`ThreadingHTTPServer` on `127.0.0.1:8765` → one background worker → yt-dlp,
ffmpeg, Tesseract/Apple Vision, and MLX Whisper. No database. Source responsibilities:

| Original file | Responsibility |
| --- | --- |
| `api/pipeline.py` | Collection listing; per-video download, OCR, transcription |
| `api/main.py` | HTTP endpoints, one active run, progress, pacing, stop/redo |
| `api/limiter.py` | Failure classification and adaptive pacing |
| `api/store.py` | Per-video JSON, thumbnails, archive/restore/purge, saved sources |
| `web/src/hooks/useLinks.ts` | Source persistence after a 400 ms debounce |
| `web/src/hooks/useRunState.ts` | Poll run state every 1,200 ms |
| `web/src/hooks/useRecords.ts` | Refetch records when the run revision changes |

Neat should retain its existing native SwiftUI → pipeline → adapters → core
structure. A localhost server, React UI, polling, and replacement transcription
engine do not help the native replacement.

## Collection intake and repeat imports

Clipmine lists collection members without downloading media:

```bash
yt-dlp --flat-playlist -J --ignore-errors --cookies-from-browser chrome "$collection_url"
```

The subprocess has a 900-second timeout. Chrome supplies the signed-in browser
session; its first cookie access can require a macOS Keychain prompt. No cookies
or credentials belong in Neat's repository or diagnostics.

`listing()` parses `entries`, discards null entries and entries without IDs, and
returns each entry's `id` and `url`. It checks for duplicate IDs **within the raw
listing** and rejects the result with “duplicate ids — TikTok repeated a page and
truncated this collection”. This guard is significant: quietly deduplicating a
repeated page would make an incomplete collection appear complete.

Limitations to improve when adapting it:

- `--ignore-errors` can yield partial output. Clipmine accepts nonempty stdout
  without checking the exit status, declared playlist count, or discarded invalid
  entries. Unique IDs alone do not prove completeness.
- The worker concatenates listings from several collections. It does not remove
  overlaps between those lists, so a new post shared by two collections can be
  processed twice in the same run.
- It derives the collection name from the final URL segment, stripping the numeric
  suffix. Shared short links need resolution before identifying a collection.
- One string `collection` per record loses multiple-source membership.

Saved collection URLs live in root-level `links.json`. `/api/links` reads/writes
them; `/api/scrape` uses a supplied list or the saved list. A repeat import lists
the sources again, then excludes IDs with an active `data/<id>.json` record.
Successful and permanently unavailable posts both receive records, making both
skip on subsequent runs. Redo explicitly selects existing records, fetches again,
and reports changed caption/OCR/transcript fields with character-count deltas.

For Neat: expand collections before per-post canonicalization and ledger dedupe;
distinguish listing failure from an empty or already-imported collection; dedupe
overlapping sources and individual pasted links together. Remembering source URLs
and exposing reimport is separate product behavior, not implicit in parsing a
collection. Neat's per-stage versions already provide more precise reprocessing
than Clipmine's whole-video Redo.

## Pacing, cooldowns, and failure taxonomy

Clipmine's limiter stores `delay` and `cooling_until` in `data/_limiter.json`.
Its exact constants and transitions are:

| Setting/event | Behavior |
| --- | --- |
| Initial delay | 8 seconds |
| Nominal bounds | 4–90 seconds |
| Success | Subtract 1 second, minimum 4; reset block/cooldown counters |
| Block | Double delay, maximum 90 |
| Three consecutive blocks | Cool down for 15, then 30, then 60 minutes |
| Exhausted cooldowns | The next three-block threshold stops the run |
| Jitter | `min(90, delay * uniform(0.8, 1.35))` |
| Permanently unavailable | Reset consecutive blocks; no delay penalty |

Jitter can make the actual wait as short as 3.2 seconds despite the nominal
4-second minimum. Collection listing has up to four attempts, backing off only
for errors classified as blocked. Per-video downloads also pass
`--sleep-interval <delay>`, `--max-sleep-interval <delay*1.6+1>`,
`--sleep-requests 2`, `--retries 5`, and `--extractor-retries 3` to yt-dlp.
The worker sleeps between posts as well, so these waits accumulate.

`classify()` checks permanent-unavailability strings first (private, removed,
deleted, missing, HTTP 404, unavailable in country), then block strings (universal
data extraction failure, challenge/captcha, HTTP 403/429, forbidden, sign-in
confirmation, rate limiting), else returns a generic error. This separates a gone
post from a transient access problem in intent, but the string matching is broad:
`rate` and `not found` can misclassify unrelated messages. Private and regional
restrictions are not necessarily permanent when account or location changes.

Do not copy these implementation bugs or overstate the README's guarantees:

- Generic OCR/transcription/tool failures also increment TikTok's block limiter in
  the per-item worker. Classification should be tied to the failing stage.
- A blocked item is skipped when the loop advances, even after a cooldown. The
  remaining queue continues; the failed item needs a later import to retry.
- Persisted `cooling_until` is loaded, but the worker never waits for it at startup.
  Only delay persistence actually affects the next run. Block and cooldown counts
  reset after restart; ordinary `cool()` calls do not clear the persisted deadline.
- Persistence uses direct writes with swallowed errors, not atomic writes.
- Stop is cooperative between operations; it does not terminate an in-flight
  subprocess or interrupt ordinary `time.sleep()` waits.

Adaptive pacing is useful for large collection runs if real imports show sustained
blocking. Porting the full policy is a separate change: preserve Neat's resumable
ledger, use cancellable waits, retain retryable states, and never burn permanent
attempts merely because the service is temporarily blocking requests.

## Bilingual OCR and media handling

Clipmine samples a video at one frame per three seconds, drops near-duplicates
with ffmpeg `mpdecimate`, limits to ten frames, and scales to 768 pixels wide. The
first frame becomes a 220-pixel-wide thumbnail. The old command uses `-vsync vfr`;
**do not copy it** because this machine's ffmpeg 9 requires `-fps_mode vfr`.

Each frame receives two local OCR passes:

1. `tesseract <frame> - -l heb+eng` supplies mixed Hebrew/English text.
2. Apple Vision through `ocrmac` supplies stylized Latin text, after querying
   supported languages and selecting `en-US` when available.

Results are merged across frames, stripping invisible bidi control marks and
deduping whitespace-normalized, lowercase lines while retaining the original text.
Tesseract stderr is discarded because non-UTF-8 output previously broke decoding;
stdout uses UTF-8 with replacement. Missing Tesseract warns; Vision exceptions are
silently ignored. The hardcoded “Vision has no Hebrew” comment is a historical
observation; query the installed OS's capabilities rather than adopting it as a
permanent fact.

MLX Whisper uses `mlx-community/whisper-large-v3-turbo` with automatic language
detection. This supports the same mixed-language use case that Neat addresses
with its existing WhisperKit stage. Clipmine's processing is video-centric; it has
no explicit slideshow/photo-mode handling to migrate.

For Neat: bidi normalization and cross-frame text dedupe are useful details to
compare with the current OCR stage. A Tesseract fallback would require a new
dependency and separate decision; keep the existing Vision/optional Anthropic
path unless that addition is requested and validated.

## Storage, archive, and cleanup tradeoffs

Clipmine keeps `data/<id>.json` plus `data/<id>.jpg`, including captions, OCR,
transcript, original URL, author, collection name, duration, status/error, and
`updatedAt`. It deletes heavy media, audio, info JSON, and frames in a `finally`
block after every attempt. Startup sweeps leftover media from interrupted runs.
This is compact but prevents re-OCR or retranscription without downloading again.

Archive moves a JSON record and thumbnail into `data/_archive/`; restore rejects
active-ID conflicts; purge deletes only archived records. IDs are validated against
path traversal, and archive mutations are rejected while a run is active. Four
storage tests cover moving both files, archive-only purge, invalid IDs, and restore
conflicts. The two file moves are not transactional. `Store.has()` checks only
active records, so an archived post can be reimported and later conflict on restore.

Neat intentionally retains original media and generic `frames/` folders, performs
atomic writes, and resumes individual stages. Do not port Clipmine's destructive
media sweep, bare file-existence completion marker, archive UI, search, tagging,
or bulk organization into Neat under the collection-support task.

## Removal audit

Exact old-project target: `/Users/hen/Developer/archive/clipmine` (a real directory,
not a symlink). At inspection:

- `data/` was empty: no records, archive, thumbnails, or limiter state to migrate.
- Root `links.json` and `.git` were absent; no `.env*` files were found outside
  dependencies. No secret contents were read or copied.
- No symlinks outside `node_modules` pointed elsewhere.
- `output/playwright/` contained eight old UI screenshots (532,664 bytes total).
  `.playwright-cli/` contained 17 capture files (66,156 bytes total).
- No running Clipmine command was found. An unrelated portfolio Vite process is
  outside the removal scope and must remain running.

The source findings above are preserved in Neat. Project deletion itself is owned
by the main task and must be recorded in `PLAN.md` after it actually occurs. Shared
tools, browser cookies, global model caches, and unrelated developer projects are
outside this directory's removal scope.
