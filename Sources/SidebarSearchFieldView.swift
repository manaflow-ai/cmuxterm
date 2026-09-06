import SwiftUI

/// SwiftUI binding adapter for the native sidebar search control.
@MainActor
struct SidebarSearchFieldView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityIdentifier: String
    let onSubmit: () -> Void
    let onCommandSubmit: () -> Void

    func makeCoordinator() -> SidebarSearchFieldCoordinator {
        SidebarSearchFieldCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> SidebarSearchField {
        let field = SidebarSearchField(frame: .zero)
        field.delegate = context.coordinator
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: SidebarSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.onCommandSubmit = onCommandSubmit
        field.applyFontScale()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: SidebarSearchField.visibleHeight)
    }
}
