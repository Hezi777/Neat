import NeatCore
import NeatPipeline
import SwiftUI

/// The one window: a source sidebar, a glass drop well, and the queue.
public struct NeatRootView: View {
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearanceRaw = Appearance.light.rawValue

    var appearance: Appearance { Appearance(rawValue: appearanceRaw) ?? .light }

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SourceSidebar(model: model)
                .navigationSplitViewColumnWidth(
                    min: NeatWindow.sidebarMin, ideal: NeatWindow.sidebarIdeal, max: 280)
        } detail: {
            if model.selectedSource.isResources {
                AllResourcesScreen(model: model)
            } else {
                QueueScreen(model: model)
            }
        }
        .frame(minWidth: NeatWindow.minWidth, minHeight: NeatWindow.minHeight)
        .preferredColorScheme(appearance.colorScheme)
        .tint(Color.neatAccent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy) { appearanceRaw = appearance.next.rawValue }
                } label: {
                    NeatIconView(appearance.toggleIcon, size: IconSize.control)
                }
                .help(appearance.toggleHelp)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showingKeySheet = true
                } label: {
                    NeatIconView(.key, size: IconSize.control)
                }
                .help(model.hasAPIKey ? "Anthropic key saved" : "Add an Anthropic key")
            }
        }
        .sheet(isPresented: .constant(!model.preflight.isSatisfied)) {
            PreflightSheet(result: model.preflight) { model.recheckTools() }
        }
        .sheet(isPresented: $model.showingKeySheet) {
            APIKeySheet(model: model)
        }
    }
}

// MARK: - Sidebar

/// Sources are separated on purpose: TikTok and Threads are different kinds of
/// material and mixing them makes the queue unreadable. This is source
/// separation, not the content organizing Neat deliberately leaves alone.
struct SourceSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedSource) {
            Section("Sources") {
                ForEach(Source.all.filter(\.isAvailable)) { source in
                    SourceRow(source: source, count: model.count(for: source))
                        .tag(source)
                }
            }

            Section("Library") {
                SourceRow(source: .resources, count: model.everyResource.count)
                    .tag(Source.resources)
            }

            // Untagged and non-interactive on purpose. Previously these were
            // selectable rows behind a binding that rejected the change, so the
            // highlight animated in and then snapped back — that was the bug.
            Section("Coming soon") {
                ForEach(Source.all.filter { !$0.isAvailable }) { source in
                    SourceRow(source: source, count: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: NeatWindow.sidebarMin)
        .tint(Color.neatAccent)
    }
}

struct SourceRow: View {
    let source: Source
    let count: Int

    var body: some View {
        HStack(spacing: Space.s) {
            NeatIconView(source.icon, size: IconSize.sidebar)
                .foregroundStyle(source.isAvailable ? .primary : .tertiary)

            Text(source.name)
                .foregroundStyle(source.isAvailable ? .primary : .tertiary)

            Spacer(minLength: Space.xs)

            if source.isAvailable, count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Queue screen

struct QueueScreen: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false
    @State private var pendingRemoval: [QueueRow] = []
    @Namespace private var glass

    var body: some View {
        VStack(spacing: Space.l) {
            GlassEffectContainer(spacing: Space.m) {
                DropWell(model: model, isTargeted: $isTargeted, namespace: glass)
            }

            if let summary = model.summary {
                SummaryBar(summary: summary, model: model)
            }

            if model.visibleRows.isEmpty {
                Spacer()
                EmptyState(source: model.selectedSource)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: Space.l) {
                    QueueList(rows: model.visibleRows, model: model) { pendingRemoval = $0 }

                    if let row = model.inspectedRow {
                        Divider()
                        ResourceInspector(model: model, row: row)
                            .frame(width: 300)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: model.selection)
            }
        }
        .padding(Space.l)
        .navigationTitle(model.selectedSource.name)
        .background(.background)
        .confirmationDialog(
            "Already in Notion",
            isPresented: Binding(get: { model.duplicatePrompt != nil },
                                 set: { if !$0 { model.duplicatePrompt = nil } }),
            presenting: model.duplicatePrompt
        ) { prompt in
            Button("Add anyway") { Task { await model.resolveDuplicate(.add) } }
            Button("Skip", role: .cancel) { Task { await model.resolveDuplicate(.skip) } }
        } message: { prompt in
            Text("\"\(prompt.resource.name)\" matches \(prompt.matches.count) existing row\(prompt.matches.count == 1 ? "" : "s") in your Resources database.")
        }
        .confirmationDialog(
            pendingRemoval.count > 1 ? "Remove \(pendingRemoval.count) items?" : "Remove this item?",
            isPresented: Binding(get: { !pendingRemoval.isEmpty },
                                 set: { if !$0 { pendingRemoval = [] } })
        ) {
            Button("Remove", role: .destructive) {
                model.remove(pendingRemoval.map(\.id))
                pendingRemoval = []
            }
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text(pendingRemoval.count > 1
                 ? "Deletes \(pendingRemoval.count) folders from disk and keeps them from coming back if you paste the links again."
                 : "Deletes \(pendingRemoval.first?.folder.lastPathComponent ?? "") from disk and keeps it from coming back if you paste the link again.")
        }
    }
}

/// Where links land. One of exactly two places glass is applied by hand.
struct DropWell: View {
    @Bindable var model: AppModel
    @Binding var isTargeted: Bool
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: Space.s) {
            NeatIconView(.dropWell, size: IconSize.hero)
                .foregroundStyle(Color.neatAccent)

            Text("Drop or paste \(model.selectedSource.name) links")
                .font(.headline)

            Text(model.selectedSource == .tiktok
                 ? "Posts or collections. Collections use your TikTok login in Chrome."
                 : "One link or a hundred.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if model.isAccepting {
                ProgressView("Reading links…")
                    .controlSize(.small)
            }

            HStack(spacing: Space.s) {
                PasteButton(payloadType: String.self) { strings in
                    Task { await model.accept(text: strings.joined(separator: "\n")) }
                }
                .buttonStyle(.glass)
                .tint(.secondary)
                .disabled(model.isWorking || model.isAccepting)

                if !model.visibleRows.isEmpty {
                    Button {
                        Task { await model.runQueue() }
                    } label: {
                        Text(model.isWorking ? "Working…" : "Start")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isWorking || model.isAccepting || !model.preflight.isSatisfied)
                }
            }
            .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: Radius.well).fill(.quaternary)
            }
        }
        .glassEffect(
            reduceTransparency ? .identity : .regular.tint(isTargeted ? Color.neatAccent.opacity(0.5) : nil),
            in: .rect(cornerRadius: Radius.well))
        .glassEffectID("well", in: namespace)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isWorking, !model.isAccepting else { return false }
            Task { await model.accept(urls: urls) }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// The line shown before any work starts.
struct SummaryBar: View {
    let summary: PasteSummary
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(summary.line)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Spacer()

                Button("Dismiss") { model.clearSummary() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.intakeErrors, id: \.self) { message in
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyState: View {
    let source: Source

    var body: some View {
        VStack(spacing: Space.m) {
            NeatIconView(.empty, size: 38)
                .foregroundStyle(.tertiary)
            Text("Nothing here yet")
                .font(.title3.weight(.medium))
            Text(source.isAvailable
                 ? "Paste \(source.name) links above and press Start."
                 : "\(source.name) isn't supported yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The queue.
///
/// A real `List` with a selection binding, not a hand-rolled stack. That is
/// what buys single-click select, double-click to open, arrow keys, type-select,
/// shift/command range selection, Delete, and VoiceOver — all of which a
/// `ScrollView` + `onTapGesture` silently throws away.
struct QueueList: View {
    let rows: [QueueRow]
    @Bindable var model: AppModel
    let onRemove: ([QueueRow]) -> Void
    @Namespace private var glass

    var body: some View {
        List(rows, selection: $model.selection) { row in
            QueueRowView(row: row, namespace: glass)
                .listRowInsets(.init(top: 3, leading: 0, bottom: 3, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                // Drag a row straight into Finder — the payload is the item's
                // own folder, which is the thing the user actually wants to move.
                .draggable(row.folder)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: CanonicalID.self) { ids in
            Button(ids.count > 1 ? "Reveal \(ids.count) in Finder" : "Reveal in Finder") {
                model.revealInFinder(ids)
            }
            Divider()
            Button(ids.count > 1 ? "Remove \(ids.count)…" : "Remove…", role: .destructive) {
                onRemove(rows.filter { ids.contains($0.id) })
            }
        } primaryAction: { ids in
            // Double-click opens the folder, matching Finder.
            model.revealInFinder(ids)
        }
        .onDeleteCommand {
            guard !model.selection.isEmpty else { return }
            onRemove(model.selectedRows)
        }
        .frame(minWidth: 360, maxWidth: .infinity)
    }
}

/// The second and last place glass is applied by hand.
struct QueueRowView: View {
    let row: QueueRow
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.m) {
            StateBadge(state: row.state, reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Space.s)

            Text(row.state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(row.state.isActive ? Color.neatAccent : .secondary)
                .contentTransition(.opacity)

            if row.isFinished {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([row.folder])
                } label: {
                    NeatIconView(.reveal, size: IconSize.control)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reveal in Finder")
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.m)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: Radius.row).fill(.quaternary)
            }
        }
        .glassEffect(reduceTransparency ? .identity : .regular, in: .rect(cornerRadius: Radius.row))
        .glassEffectID(row.id.folderName, in: namespace)
        .animation(reduceMotion ? nil : .snappy, value: row.state)
        .contentShape(.rect)
    }
}

/// Row state must be legible at a glance without reading the label, so the
/// icon changes and active states spin.
struct StateBadge: View {
    let state: ItemState
    let reduceMotion: Bool
    @State private var spin = false

    var body: some View {
        NeatIconView(state.icon, size: IconSize.row)
            .foregroundStyle(tint)
            .rotationEffect(.degrees(state.isActive && spin && !reduceMotion ? 360 : 0))
            .animation(
                state.isActive && !reduceMotion
                    ? .linear(duration: 1.6).repeatForever(autoreverses: false)
                    : .default,
                value: spin)
            .onAppear { spin = true }
            .frame(width: IconSize.row + 6)
    }

    var tint: Color {
        switch state {
        case .done: .green
        case .dead: .orange
        case .queued, .skipped: .secondary
        default: Color.neatAccent
        }
    }
}

// MARK: - Sheets

/// Shown when yt-dlp or ffmpeg is missing. Not a crash, not a silent failure.
struct PreflightSheet: View {
    let result: PreflightResult
    let recheck: () -> Void

    var missingList: String {
        ListFormatter.localizedString(byJoining: result.missing.map(\.rawValue))
    }

    var body: some View {
        VStack(spacing: Space.m) {
            NeatIconView(.tools, size: IconSize.hero)
                .foregroundStyle(.secondary)

            Text("Missing tools")
                .font(.title2.weight(.semibold))

            Text("Neat needs \(missingList) on your PATH.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let command = result.brewCommand {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(Space.s)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
            }

            Button("Recheck", action: recheck)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Space.xl)
        .frame(width: 380)
    }
}

/// The key is written straight to the Keychain and never held in the model.
struct APIKeySheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(spacing: Space.m) {
            NeatIconView(.key, size: IconSize.hero)
                .foregroundStyle(.secondary)

            Text("Anthropic API key")
                .font(.title2.weight(.semibold))

            Text("Used only to re-read frames the on-device reader could not. Stored in your Keychain.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack(spacing: Space.s) {
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.saveAPIKey(key)
                    key = ""
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 400)
    }
}

#Preview {
    NeatRootView()
}
