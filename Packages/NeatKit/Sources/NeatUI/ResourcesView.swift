import NeatCore
import NeatPipeline
import SwiftUI

/// What happened when a resource was pushed to Notion.
public enum PushState: Sendable, Equatable {
    case idle
    case working
    case pushed
    case failed(String)
}

/// A duplicate Notion row that needs a decision, Finder-style.
public struct DuplicatePrompt: Identifiable, Sendable {
    public let id: String
    public let resource: Resource
    public let matches: [NotionMatch]
    public let item: CanonicalID
}

/// The right-hand pane: what Groq pulled out of one item, and the way it gets
/// into Notion.
struct ResourceInspector: View {
    @Bindable var model: AppModel
    let row: QueueRow

    var resources: [Resource] { model.resources(for: row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text("Resources")
                    .font(.headline)
                Spacer()
                if model.isExtracting.contains(row.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Extract") { Task { await model.extract(row.id) } }
                        .buttonStyle(.glass)
                        .disabled(!model.canExtract)
                }
            }

            if resources.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(model.canExtract
                         ? "Nothing extracted yet."
                         : "Add a Groq key to extract resources.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.s) {
                        ForEach(resources) { resource in
                            ResourceCard(model: model, item: row.id, resource: resource)
                        }
                    }
                }

                Button {
                    Task { await model.pushAll(for: row.id) }
                } label: {
                    Label("Send unsent to Notion", systemImage: "")
                        .labelStyle(.titleOnly)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(!model.canPushToNotion || resources.allSatisfy(\.pushedToNotion))
            }
        }
        .padding(Space.l)
        .frame(minWidth: 260)
    }
}

struct ResourceCard: View {
    @Bindable var model: AppModel
    let item: CanonicalID
    let resource: Resource

    var state: PushState { model.pushState[resource.id] ?? .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(resource.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                statusBadge
            }

            if !resource.summary.isEmpty {
                Text(resource.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let url = resource.url, let link = URL(string: url) {
                Link(destination: link) {
                    Text(url)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !resource.category.isEmpty {
                // Wraps rather than clipping — a resource can carry several.
                FlowRow(spacing: Space.xs) {
                    ForEach(resource.category, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: Radius.row))
        .contextMenu {
            if !resource.pushedToNotion {
                Button("Send to Notion") { Task { await model.push(resource, for: item) } }
                    .disabled(!model.canPushToNotion)
            }
            if let url = resource.url {
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    var statusBadge: some View {
        switch state {
        case .working:
            ProgressView().controlSize(.small)
        case .failed(let why):
            NeatIconView(.unavailable, size: 14)
                .foregroundStyle(.orange)
                .help(why)
        case .pushed:
            NeatIconView(.done, size: 14).foregroundStyle(.green)
        case .idle:
            if resource.pushedToNotion {
                NeatIconView(.done, size: 14)
                    .foregroundStyle(.green)
                    .help("Already in Notion")
            } else {
                Button {
                    Task { await model.push(resource, for: item) }
                } label: {
                    Text("Add")
                        .font(.caption)
                }
                .buttonStyle(.glass)
                .disabled(!model.canPushToNotion)
            }
        }
    }
}

/// Everything extracted across every item, for bulk review.
struct AllResourcesScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.everyResource.isEmpty {
                VStack(spacing: Space.m) {
                    NeatIconView(.empty, size: 38).foregroundStyle(.tertiary)
                    Text("No resources yet")
                        .font(.title3.weight(.medium))
                    Text(model.canExtract
                         ? "Run the queue — extraction happens after the on-screen text is read."
                         : "Add a Groq key to ~/Neat/.env to extract resources.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.s) {
                        ForEach(model.everyResource, id: \.resource.id) { pair in
                            ResourceCard(model: model, item: pair.item.id, resource: pair.resource)
                        }
                    }
                    .padding(Space.l)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Resources")
    }
}

/// A minimal wrapping row. SwiftUI has no built-in flow layout and the category
/// tags must wrap rather than clip.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
