import CoreGraphics
import Foundation
import NeatCore

/// Pulls the re-findable resources out of an item and writes `resources.json`.
///
/// Groq is OpenAI-compatible, so this is raw HTTP against
/// `/openai/v1/chat/completions` — there is no official Groq SDK for Swift.
///
/// The stage sends images as well as text. OCR reliably misses what a slideshow
/// or a Threads screenshot is actually recommending: a tool name inside a
/// terminal screenshot, a URL rendered in a small caption, a logo with no text
/// at all. The frames are the point, not a bonus.
public struct ExtractStage: Stage {
    public let name = "extract"
    public let version = StageVersions.extract

    /// Groq serves this as a preview model; expect to swap it. One constant so
    /// that swap is one line.
    public static let model = "qwen/qwen3.6-27b"

    public static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    /// How many frames one request carries. The model itself accepts 3 — a
    /// fourth is rejected with "Too many images provided. This model supports up
    /// to 3 images" — but 3 is unreachable on Groq's free tier: its rate limiter
    /// estimates an image at roughly 2,048 input tokens, so three of them plus
    /// this pipeline's text is "Requested 7683" against a 7,000 ITPM allowance
    /// and never runs. Two frames measured 2,610 real prompt tokens and pass.
    /// Raise this to 3 on a paid tier. Swap it with `model`.
    public static let maxImages = 2

    /// Groq estimates a request's output before running it and rejects the whole
    /// call when that estimate exceeds the account's output-tokens-per-minute
    /// allowance (1000 on the free tier). Without an explicit cap it assumes the
    /// model's default of 1484 and every request 429s before reaching the model.
    public static let maxOutputTokens = 900

    /// Smaller than the OCR fallback's 768. The fallback exists to read fine
    /// print; this stage looks at shapes, logos and layout, because the text was
    /// already read into `transcript.txt` and `onscreen.txt` and is sent
    /// alongside.
    ///
    /// This buys upload bytes, **not** tokens. Measured against the live API,
    /// one frame costs 783 prompt tokens at 768px, 512px and 256px alike —
    /// Groq prices an image flat, regardless of its pixels. Only `maxImages`
    /// moves the token cost.
    public static let maxDimension: CGFloat = 512

    /// Groq supplies `retry-after` on a rate limit, so the wait is its figure
    /// rather than a guess. Capped because one item must not stall the sweep.
    public static let maxRateLimitWait = Duration.seconds(60)
    /// Tries inside the stage before the item goes back to the queue untouched.
    public static let rateLimitRetries = 3

    let secrets: SecretsStore
    let session: URLSession

    public init(secrets: SecretsStore = SecretsStore(), session: URLSession = .shared) {
        self.secrets = secrets
        self.session = session
    }

    public func run(_ item: Item, paths: NeatPaths) async throws -> Item {
        var item = item
        guard item.stages.extract.needsRun(currentVersion: version) else { return item }

        // No key is not a failure. Extraction is an extra on top of a pipeline
        // that already works, so the item is marked as not applicable rather
        // than left pending or thrown out of the run.
        guard let apiKey = secrets.value(for: .groq) else {
            Log.pipeline.notice("no Groq key set; skipping extract for \(item.id.folderName, privacy: .public)")
            item.stages.extract = .skippedStage(v: version)
            return item
        }

        let context = Self.context(for: item, paths: paths)
        let frames = Self.evenlySpread(
            OnscreenStage.frameFiles(in: paths.frames(item.id)), cap: Self.maxImages)

        let fresh = try await extract(context: context, frames: frames, apiKey: apiKey)

        // Merging rather than replacing is what stops a re-run forgetting which
        // resources have already been pushed to Notion.
        let existing = Self.loadResources(paths.resources(item.id))
        let merged = ResourcesFile.merge(existing: existing, fresh: fresh)

        // An empty array is a real answer — most posts recommend nothing. It is
        // written so the stage does not re-run forever looking for something.
        try atomicWriteJSON(ResourcesFile(v: version, resources: merged), to: paths.resources(item.id))

        item.stages.extract = .completed(v: version)
        return item
    }

    // MARK: - Input

    /// Everything the pipeline already knows about the item, as plain text.
    /// `body.txt` only exists for Threads posts; the rest are optional too,
    /// because a stage may legitimately have been skipped.
    static func context(for item: Item, paths: NeatPaths) -> String {
        var parts: [String] = []

        func section(_ label: String, _ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            parts.append("--- \(label) ---\n\(text)")
        }

        section("caption", item.caption)
        section("post body", try? String(contentsOf: paths.body(item.id), encoding: .utf8))
        section("transcript", try? String(contentsOf: paths.transcript(item.id), encoding: .utf8))
        section("on-screen text", try? String(contentsOf: paths.onscreen(item.id), encoding: .utf8))

        return parts.isEmpty ? "(no text available for this post)" : parts.joined(separator: "\n\n")
    }

    /// An evenly spread subset, not the first N — the recommendation in a
    /// six-slide tutorial is usually on the last slide.
    static func evenlySpread(_ files: [URL], cap: Int) -> [URL] {
        guard cap > 0 else { return [] }
        guard files.count > cap else { return files }
        if cap == 1 { return [files[0]] }

        let indices = (0..<cap).map { Int((Double($0) * Double(files.count - 1) / Double(cap - 1)).rounded()) }
        return Array(Set(indices)).sorted().map { files[$0] }
    }

    static func loadResources(_ url: URL) -> [Resource] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? NeatJSON.decoder.decode(ResourcesFile.self, from: data))?.resources ?? []
    }

    // MARK: - The call

    static let prompt = """
        You are reading one saved social post. List the resources it recommends \
        or demonstrates — tools, libraries, websites, docs, repos, products, \
        courses — that someone could go and find again later.

        Rules:
        - Only include something the post itself actually points at. Do not add \
        things that are merely adjacent or that you happen to know about.
        - Include a URL only when it is visible in the text or on screen. Never \
        invent a URL and never guess one from a product name. Use null instead.
        - Never return the source post, its author, or the platform it is on as \
        a resource.
        - `summary` is one line, at most 200 characters, saying what the thing \
        is and why the post mentions it.
        - `category` may only contain the allowed values. Use an empty array \
        rather than a category that does not fit.
        - Most posts recommend nothing. An empty array is a correct answer and \
        is expected to be common.
        """

    /// Structured outputs, so the shape is guaranteed rather than parsed
    /// hopefully. The category enum is the same ten strings the Notion database
    /// accepts, which is why the model cannot invent one here.
    static var responseFormat: [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "resources",
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["resources"],
                    "properties": [
                        "resources": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "required": ["name", "url", "category", "summary"],
                                "properties": [
                                    "name": ["type": "string"],
                                    "url": ["type": ["string", "null"]],
                                    "category": [
                                        "type": "array",
                                        "items": ["type": "string", "enum": Resource.categories],
                                    ],
                                    "summary": ["type": "string"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    func extract(context: String, frames: [URL], apiKey: String) async throws -> [Resource] {
        var content: [[String: Any]] = [["type": "text", "text": "\(Self.prompt)\n\n\(context)"]]

        for frame in frames {
            guard let jpeg = AnthropicOCR.downscaledJPEG(frame, maxDimension: Self.maxDimension) else {
                Log.pipeline.error("could not encode frame \(frame.lastPathComponent, privacy: .public) for extract")
                continue
            }
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
            ])
        }

        let body: [String: Any] = [
            "model": Self.model,
            "temperature": 0,
            "max_tokens": Self.maxOutputTokens,
            // This model reasons by default and spends the entire output budget
            // doing it — observed at 681 tokens for a trivial prompt — leaving
            // nothing for the JSON and failing the request as `json_validate_failed`
            // with an empty generation. "none" is supported by exactly this model.
            "reasoning_effort": "none",
            "messages": [["role": "user", "content": content]],
            "response_format": Self.responseFormat,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        return try Self.parse(try await sendRetryingRateLimits(request))
    }

    /// Retries only a 429, and only as many times as `rateLimitRetries`. Every
    /// other failure is returned immediately — retrying a bad request just
    /// makes the same mistake more slowly.
    func sendRetryingRateLimits(_ request: URLRequest) async throws -> Data {
        var lastError: (any Error)?

        for attempt in 1...Self.rateLimitRetries {
            do {
                return try await send(request)
            } catch let error as StageError {
                guard case .rateLimited(let retryAfter, _) = error else { throw error }
                lastError = error
                guard attempt < Self.rateLimitRetries else { break }

                let wait = retryAfter ?? .seconds(5)
                Log.pipeline.notice("Groq rate limited, waiting before attempt \(attempt + 1, privacy: .public)")
                try? await Task.sleep(for: wait)
            }
        }

        throw lastError ?? StageError.fetchFailed("Groq rate limit")
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw StageError.fetchFailed("no response from Groq API")
        }
        if http.statusCode == 200 { return data }

        let detail = String(String(decoding: data, as: UTF8.self).prefix(300))

        // 413 is not "wait and try again", whatever its `retry-after` says:
        // Groq rejects the payload as too large for the tier even when the
        // whole token allowance is free (observed alongside
        // `x-ratelimit-remaining-tokens: 8000`). Waiting never makes it fit, so
        // this is a real failure and says what would actually help.
        if http.statusCode == 413 {
            throw StageError.fetchFailed(
                "Groq API 413 — the request is too large for this account's tier. "
                    + "Lower `maxImages` (currently \(Self.maxImages)) or upgrade. \(detail)")
        }

        if http.statusCode == 429 {
            throw StageError.rateLimited(retryAfter: Self.retryAfter(http), detail: detail)
        }

        throw StageError.fetchFailed("Groq API \(http.statusCode): \(detail)")
    }

    /// The service's own `retry-after`, in seconds, clamped to something a
    /// single item is allowed to wait.
    static func retryAfter(_ http: HTTPURLResponse) -> Duration? {
        guard let raw = http.value(forHTTPHeaderField: "retry-after"),
              let seconds = Double(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0
        else { return nil }
        return .seconds(min(seconds, 60))
    }

    /// Reads the OpenAI-shaped envelope, then the JSON document the model put in
    /// the message content, then sanitizes every row. Categories outside the ten
    /// are dropped here as a second line of defence — the schema should already
    /// have prevented them, but the file must be clean whatever the model does.
    static func parse(_ data: Data) throws -> [Resource] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String
        else { throw StageError.fetchFailed("unexpected Groq response shape") }

        // `try?` on the inner document deliberately: a model that returned
        // prose instead of JSON is the same failure as one that returned the
        // wrong shape, and both should read that way rather than surfacing a
        // raw NSCocoaErrorDomain parse error.
        guard let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let rows = payload["resources"] as? [[String: Any]]
        else { throw StageError.fetchFailed("Groq returned content that is not the requested schema") }

        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return Resource.make(
                name: name,
                url: row["url"] as? String,
                category: row["category"] as? [String] ?? [],
                summary: row["summary"] as? String ?? "")
        }
    }
}
