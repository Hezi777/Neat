import Foundation
import NeatCore
import NeatPipeline

// A thin harness so the pipeline can be exercised end-to-end from a terminal,
// against a throwaway root, without going through the window.
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: neat-cli <root> [--intake-only] <url>...")
    exit(2)
}

let root = URL(filePath: args[1])
let paths = NeatPaths(root: root)
let intakeOnly = args.dropFirst(2).contains("--intake-only")
let urls = args.dropFirst(2).filter { $0 != "--intake-only" }

let intake = PasteIntake(items: ItemStore(paths: paths), ledgerStore: LedgerStore(paths: paths))
let result = await intake.intake(text: urls.joined(separator: "\n"))
print("summary: \(result.summary.line)")
for entry in result.entries {
    if case .invalid(let message) = entry.disposition { print("  \(message)") }
}

let library = Library(paths: paths, stages: [
    FetchStage(), TranscribeStage(),
    OnscreenStage(secrets: SecretsStore(paths: paths)),
    ExtractStage(secrets: SecretsStore(paths: paths)),
])
try library.enqueue(result)
if intakeOnly { exit(result.summary.invalid == 0 ? 0 : 1) }

await library.run { event in
    print("  [\(event.id.folderName)] \(event.state)")
}

func describe(_ label: String, _ state: StageState) -> String {
    var parts = ["done=\(state.done)"]
    if state.skipped { parts.append("skipped=true") }
    parts.append("v\(state.v)")
    if let error = state.error { parts.append("err=\(error)") }
    return "    \(label.padding(toLength: 11, withPad: " ", startingAt: 0)) \(parts.joined(separator: " "))"
}

for item in library.allItems() {
    print("\n\(item.id.folderName)")
    print("    type       \(item.type.map(String.init(describing:)) ?? "nil")")
    print("    author     \(item.author ?? "nil")")
    print("    caption    \(String((item.caption ?? "").prefix(60)))")
    print(describe("fetch", item.stages.fetch))
    print(describe("transcribe", item.stages.transcribe))
    print(describe("onscreen", item.stages.onscreen))
    print(describe("extract", item.stages.extract))

    if let text = try? String(contentsOf: paths.transcript(item.id), encoding: .utf8) {
        print("    transcript \(text.count) chars")
    }
    if let text = try? String(contentsOf: paths.onscreen(item.id), encoding: .utf8) {
        print("    onscreen   \(text.count) chars")
    }

    for resource in library.resources(for: item.id) {
        print("    resource   \(resource.name) [\(resource.category.joined(separator: ", "))] \(resource.url ?? "-")")
    }
}
