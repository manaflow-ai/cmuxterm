import SwiftUI

/// Eager settings content with enough trailing space to top-align every navigation anchor.
struct SettingsSectionScrollContent<Content: View>: View {
    let viewportHeight: CGFloat
    let content: Content
    @State private var lastSectionHeight: CGFloat = 0

    init(viewportHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.viewportHeight = viewportHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SettingsSectionScrollGeometryKey.self,
                    value: SettingsSectionScrollGeometry(
                        contentBottomY: proxy.frame(in: .named(SettingsSectionScrollTracker.coordinateSpace)).maxY
                    )
                )
            }
        }
        .onPreferenceChange(SettingsSectionScrollGeometryKey.self) { geometry in
            if let height = geometry.lastSectionHeight, height != lastSectionHeight {
                lastSectionHeight = height
            }
        }
        .padding(.bottom, SettingsSectionScrollTracker().bottomPadding(
            viewportHeight: viewportHeight,
            lastSectionHeight: lastSectionHeight
        ))
    }
}
