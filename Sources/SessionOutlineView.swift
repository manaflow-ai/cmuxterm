import CmuxAgentChat
import SwiftUI

struct SessionOutlineTerminalOverlay: View {
    let panel: TerminalPanel
    let transcriptService: AgentChatTranscriptService?
    let model: SessionOutlineModel

    var body: some View {
        Group {
            if model.isAvailable {
                VStack(alignment: .trailing, spacing: 8) {
                    if model.isPresented {
                        SessionOutlinePanelView(
                            entries: model.entries,
                            onSelect: { entry in
                                model.beginJump(to: entry)
                            },
                            onDismiss: {
                                model.dismissPresentation()
                            }
                        )
                    }
                    Button {
                        _ = model.togglePresentation()
                    } label: {
                        CmuxSystemSymbolImage(
                            systemName: "list.bullet.rectangle",
                            pointSize: 13,
                            weight: .medium,
                            tint: .primary
                        )
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("SessionOutlineToggle")
                    .accessibilityLabel(Text(String(
                        localized: "sessionOutline.toggle",
                        defaultValue: "Session Outline"
                    )))
                    .help(String(localized: "sessionOutline.toggle", defaultValue: "Session Outline"))
                }
                .padding(10)
            }
        }
        .task(id: panel.id) {
            await model.observe(panel: panel, transcriptService: transcriptService)
        }
    }
}

struct SessionOutlinePanelView: View {
    let entries: [ChatOutlineEntry]
    let onSelect: (ChatOutlineEntry) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "sessionOutline.title", defaultValue: "Session Outline"))
                    .cmuxFont(size: 13, weight: .semibold)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    CmuxSystemSymbolImage(systemName: "xmark", pointSize: 10, weight: .semibold, tint: .primary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "common.close", defaultValue: "Close")))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        SessionOutlineEntryRow(entry: entry) {
                            onSelect(entry)
                        }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 430)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .accessibilityIdentifier("SessionOutlinePanel")
    }
}

private struct SessionOutlineEntryRow: View {
    let entry: ChatOutlineEntry
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .cmuxFont(size: 12)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(entry.timestamp, format: .dateTime.hour().minute())
                        .cmuxFont(size: 10)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if entry.hasAlert {
                    CmuxSystemSymbolImage(
                        systemName: "exclamationmark.circle.fill",
                        pointSize: 11,
                        weight: .medium,
                        tint: .orange
                    )
                    .accessibilityLabel(Text(String(
                        localized: "sessionOutline.actionRequired",
                        defaultValue: "Action required"
                    )))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SessionOutlineEntry-\(entry.id)")
    }
}
