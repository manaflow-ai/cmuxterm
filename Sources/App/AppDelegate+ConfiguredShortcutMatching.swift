import AppKit

extension AppDelegate {
    private func resolvedPrefixChordOwns(_ action: KeyboardShortcutSettings.Action) -> Bool {
        guard let resolvedActionID = activeResolvedPrefixChordActionID else { return true }
        return resolvedActionID == action.rawValue
    }

    func resolvedShortcutEventWindow(_ event: NSEvent) -> NSWindow? {
        if let window = event.window {
            return window
        }
        let eventWindowNumber = event.windowNumber
        guard eventWindowNumber > 0 else { return nil }
        return NSApp.window(withWindowNumber: eventWindowNumber)
    }

    func matchConfiguredShortcut(
        event: NSEvent,
        shortcut: StoredShortcut
    ) -> Bool {
        if event.type == .keyDown,
           activeResolvedPrefixChordWasSystemDefined,
           let resolvedActionID = activeResolvedPrefixChordActionID,
           let resolvedAction = KeyboardShortcutSettings.Action(rawValue: resolvedActionID),
           shortcut == KeyboardShortcutSettings.shortcut(for: resolvedAction) {
            // A system-defined suffix is dispatched through a sanitized
            // keyDown proxy. The router already proved the exact binding, so
            // do not ask the proxy to impersonate an unrepresentable media
            // stroke; only the selected action may match this event.
            return true
        }
        guard let stroke = routableConfiguredShortcutStroke(
            event: event,
            shortcut: shortcut
        ) else { return false }
        return matchShortcutStroke(event: event, stroke: stroke)
    }

    func matchConfiguredShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Bool {
        guard resolvedPrefixChordOwns(action) else { return false }
        guard shortcutWhenClauseAllows(action: action, event: event) else {
            return false
        }
        if event.type == .keyDown, activeResolvedPrefixChordWasSystemDefined {
            return true
        }
        return matchConfiguredShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: action)
        )
    }

    /// `shortcuts.when` gates opening Search; visible Search owns its toggle so
    /// the auxiliary popover's transient focus context cannot prevent dismissal.
    func globalSearchShortcutWhenClauseAllows(event: NSEvent) -> Bool {
        GlobalSearchCoordinator.shared.isPaletteVisible()
            || KeyboardShortcutSettings.effectiveWhenClause(for: .globalSearch)
                .evaluate(shortcutEventFocusContext(event).shortcutContext)
    }

    /// Whether the action's effective `shortcuts.when` predicate permits the event.
    func shortcutWhenClauseAllows(
        action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        if action == .globalSearch {
            return globalSearchShortcutWhenClauseAllows(event: event)
        }
        return KeyboardShortcutSettings.effectiveWhenClause(for: action)
            .evaluate(shortcutEventFocusContext(event).shortcutContext)
    }

    /// Resolves a right-sidebar mode shortcut after applying its effective predicate.
    func rightSidebarModeShortcut(for event: NSEvent) -> RightSidebarMode? {
        rightSidebarModeShortcut(
            for: event,
            allowingAction: { [self] action in
                shortcutWhenClauseAllows(action: action, event: event)
            }
        )
    }

    /// Resolves a right-sidebar mode with a caller-supplied context predicate
    /// while retaining the shared configured-shortcut matcher.
    func rightSidebarModeShortcut(
        for event: NSEvent,
        allowingAction: (KeyboardShortcutSettings.Action) -> Bool
    ) -> RightSidebarMode? {
        let shortcutWindow = resolvedShortcutEventWindow(event)
            ?? event.window
            ?? shortcutRoutingActiveWindow
        if shortcutRoutingShouldBypassForPrintableOptionText(event: event),
           shortcutResponderHasMarkedText(shortcutWindow?.firstResponder) {
            return nil
        }
        return KeyboardShortcutSettingsObserver.shared
            .rightSidebarModeShortcutMatcher.modeShortcut(
                for: event,
                allowingAction: allowingAction,
                matching: { [self] action, _, event in
                    matchConfiguredShortcut(event: event, action: action)
                }
            )
    }

    func shouldForwardBrowserSurfaceShortcutToTerminal(_ event: NSEvent) -> Bool {
        KeyboardShortcutSettings.Action.allCases.contains {
            resolvedPrefixChordOwns($0)
                && $0.shortcutContext.forwardsMenuEquivalentToFocusedTerminal
                && !$0.isBrowserContentShortcut
                && matchConfiguredShortcut(
                    event: event,
                    shortcut: KeyboardShortcutSettings.shortcut(for: $0)
                )
        }
    }

    private func numberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard let stroke = routableConfiguredShortcutStroke(
            event: event,
            shortcut: shortcut
        ) else { return nil }
        return numberedShortcutDigit(event: event, stroke: stroke)
    }

    func routableNumberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        guard resolvedPrefixChordOwns(action) else { return nil }
        guard let digit = numberedConfiguredShortcutDigit(
            event: event,
            action: action
        ), shortcutWhenClauseAllows(action: action, event: event) else {
            return nil
        }
        return digit
    }

    func matchConfiguredDirectionalShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        guard resolvedPrefixChordOwns(action),
              !shouldBypassPrefixChordPassThrough(event),
              shortcutWhenClauseAllows(action: action, event: event) else {
            return false
        }
        if event.type == .keyDown, activeResolvedPrefixChordWasSystemDefined {
            // The router already matched the media suffix. Directional
            // actions are selected by the resolved action branch itself, so
            // there is no keyboard arrow to reconstruct on the proxy event.
            return true
        }
        guard let stroke = routableConfiguredShortcutStroke(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: action)
        ) else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: stroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    /// Resolves the one stroke that the ordinary shortcut path may route for
    /// this event. Prefix state, pass-through markers, unbound values, and
    /// chord-vs-single semantics are shared by every surface-specific matcher.
    private func routableConfiguredShortcutStroke(
        event: NSEvent,
        shortcut: StoredShortcut
    ) -> ShortcutStroke? {
        guard !shouldBypassPrefixChordPassThrough(event),
              !shortcut.isUnbound else {
            return nil
        }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke.isRoutingEquivalent(to: prefix) else {
                return nil
            }
            return secondStroke
        }
        guard !shortcut.hasChord else { return nil }
        return shortcut.firstStroke
    }
}
