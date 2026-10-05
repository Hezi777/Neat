import Foundation
import NeatCore
import NeatPipeline
import Observation

/// Holds what the window is showing. One model, no coordinator layer.
@MainActor
@Observable
public final class IntakeModel {
    public private(set) var result: IntakeResult?
    public private(set) var isWorking = false
    public private(set) var preflight: PreflightResult

    let intake: PasteIntake

    public init(intake: PasteIntake = PasteIntake(), preflight: PreflightResult? = nil) {
        self.intake = intake
        self.preflight = preflight ?? ToolPreflight().check()
    }

    public func recheckTools() {
        preflight = ToolPreflight().check()
    }

    /// Classify a paste. Deliberately does not start any work — M1 shows the
    /// summary before anything downloads.
    public func accept(text: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        result = await intake.intake(text: text)
    }

    public func accept(urls: [URL]) async {
        await accept(text: urls.map(\.absoluteString).joined(separator: "\n"))
    }

    public func clear() { result = nil }
}
