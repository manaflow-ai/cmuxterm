struct MainWindowZoomIntentState: Sendable, Equatable {
    private(set) var isZoomed = false
    private(set) var isApplyingManagedPlacement = false

    var wantsZoomedFrame: Bool {
        isZoomed
    }

    mutating func recordZoom(isZoomed: Bool) {
        self.isZoomed = isZoomed
    }

    mutating func beginManagedPlacement() {
        isApplyingManagedPlacement = true
    }

    mutating func endManagedPlacement() {
        isApplyingManagedPlacement = false
    }

    mutating func recordUserPlacement() {
        guard !isApplyingManagedPlacement else { return }
        isZoomed = false
    }
}
