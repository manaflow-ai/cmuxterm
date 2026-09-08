import SwiftUI

/// Another Mac's header row, on the same grid as the cloud machine row. Unlike
/// cloud rows (which dropped their status dot), a device row keeps a presence
/// glyph in the dot slot: liveness is the one fact a person needs before
/// clicking, and it changes under them while the tree is open.
struct CloudTreeDeviceRowContent: View {
    let row: CloudTreeDeviceRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current
    /// Injected so rows never read the wall clock in `body` on their own.
    var now: Date = Date()

    var body: some View {
        switch style.machineRowLayout {
        case .singleLine:
            CloudTreeMachineBand(style: style) {
                HStack(alignment: .center, spacing: CloudTreeRowGrid.dotGap) {
                    presenceGlyph
                        .frame(width: CloudTreeRowGrid.dotSlot, alignment: .center)
                    HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.dotGap) {
                        Text(row.name)
                            .cmuxFont(size: style.machineNameSize, weight: style.machineBand ? .semibold : .medium, design: style.fontDesign)
                            .foregroundStyle(row.isOnline ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(row.statusLabel(now: now))
                            .cmuxFont(size: style.detailSize, design: style.fontDesign)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: CloudTreeRowGrid.trailingGap)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        case .twoLine:
            HStack(alignment: .top, spacing: CloudTreeRowGrid.dotGap) {
                presenceGlyph
                    .frame(width: CloudTreeRowGrid.dotSlot, height: style.machineNameLineHeight, alignment: .center)
                VStack(alignment: .leading, spacing: CloudTreeRowGrid.machineLineSpacing) {
                    Text(row.name)
                        .cmuxFont(size: style.machineNameSize, weight: .medium, design: style.fontDesign)
                        .foregroundStyle(row.isOnline ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: style.machineNameLineHeight)
                    Text(Self.subtitle(row, now: now))
                        .cmuxFont(size: style.detailSize + 0.5, design: style.fontDesign)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: style.machineSubtitleLineHeight)
                }
                Spacer(minLength: CloudTreeRowGrid.trailingGap)
            }
            .padding(.vertical, style.machineVerticalPadding)
            .padding(.trailing, CloudTreeRowGrid.trailingPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: String {
        "\(row.name), \(row.statusLabel(now: now))"
    }

    /// A filled dot for a live device, a hollow one while its link is being
    /// made, a dim dot when offline, and the warning color when the link failed.
    @ViewBuilder
    private var presenceGlyph: some View {
        switch row.indicator {
        case .online:
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .help(String(localized: "cloudTree.device.presence.online", defaultValue: "Online"))
        case .connecting:
            Circle()
                .strokeBorder(Color.green, lineWidth: 1.5)
                .frame(width: 7, height: 7)
                .help(String(localized: "cloudTree.device.presence.connecting", defaultValue: "Connecting"))
        case .attention:
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
                .help(String(localized: "cloudTree.device.presence.attention", defaultValue: "Needs attention"))
        case .offline:
            Circle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .help(String(localized: "cloudTree.device.presence.offline", defaultValue: "Offline"))
        }
    }

    /// "Online · 3 workspaces · 5 terminals", or the status alone when offline.
    static func subtitle(_ row: CloudTreeDeviceRow, now: Date) -> String {
        var parts = [row.statusLabel(now: now)]
        guard row.isOnline else { return parts[0] }
        if row.workspaceCount > 0 {
            parts.append(
                row.workspaceCount == 1
                    ? String(localized: "cloudTree.device.workspaceCount.one", defaultValue: "1 workspace")
                    : String(format: String(localized: "cloudTree.device.workspaceCount.other", defaultValue: "%d workspaces"), row.workspaceCount)
            )
        }
        if row.terminalCount > 0 {
            parts.append(CloudTreeRowContentView.count(row.terminalCount))
        }
        return parts.joined(separator: " · ")
    }
}
