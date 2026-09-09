import Foundation

/// Validates the JSON shapes consumed by cmux's configuration decoder.
///
/// This validator intentionally works on Foundation JSON values so the app
/// and the standalone CLI can share the same command-entry contract without
/// importing the AppKit-backed config store into the CLI target.
struct CmuxConfigTypeValidator: Sendable {
    private let workspaceColorNames: Set<String>

    init(workspaceColorNames: Set<String>? = nil) {
        let names = workspaceColorNames ?? Self.workspaceColorNames(from: .standard)
        self.workspaceColorNames = Set(
            names.compactMap {
                let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            }
        )
    }

    static let builtInWorkspaceColorNames = [
        "Red", "Crimson", "Orange", "Amber", "Olive", "Green", "Teal", "Aqua",
        "Blue", "Navy", "Indigo", "Purple", "Magenta", "Rose", "Brown", "Charcoal",
    ]

    static func workspaceColorNames(from defaults: UserDefaults) -> Set<String> {
        if let configured = defaults.dictionary(forKey: "workspaceTabColor.colors") as? [String: String] {
            // `storedPaletteMap` replaces the built-in map, so only entries
            // with a valid persisted hex value are available at runtime.
            return Set(configured.compactMap { name, hex in
                guard Self.isSixDigitHexColor(hex) else { return nil }
                let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalizedName.isEmpty ? nil : normalizedName
            })
        }
        var names = Set(builtInWorkspaceColorNames)
        // Keep a normalized companion set so generated Custom N names can be
        // checked in O(1) while preserving the original display casing in the
        // returned palette-name set.
        var normalizedNames = Set(names.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        if let overrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String] {
            // The runtime legacy resolver only accepts overrides for the
            // built-in palette. Arbitrary keys are discarded there and must
            // not make doctor accept a color that runtime rejects.
            names.formUnion(overrides.compactMap { name, hex in
                guard builtInWorkspaceColorNames.contains(name),
                      Self.isSixDigitHexColor(hex) else { return nil }
                return name
            })
        }
        if let customColors = defaults.array(forKey: "workspaceTabColor.customColors") as? [String] {
            var index = 1
            var seenHexes = Set<String>()
            for rawHex in customColors {
                guard let normalized = normalizedHexColor(rawHex), seenHexes.insert(normalized).inserted else {
                    continue
                }
                while normalizedNames.contains("custom \(index)".lowercased()) {
                    index += 1
                }
                let generatedName = "Custom \(index)"
                names.insert(generatedName)
                normalizedNames.insert(generatedName.lowercased())
                index += 1
            }
        }
        return names
    }

    func issues(in object: Any) -> [CmuxConfigTypeIssue] {
        guard let root = object as? [String: Any] else {
            return [issue(path: "root", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")])]
        }

        var issues: [CmuxConfigTypeIssue] = []
        validateRoot(root, issues: &issues)
        return issues
    }

    private func validateRoot(
        _ root: [String: Any],
        issues: inout [CmuxConfigTypeIssue]
    ) {
        if let rawActions = root["actions"], !isNull(rawActions) {
            validateActions(rawActions, path: "actions", issues: &issues)
        }
        if let rawUI = root["ui"], !isNull(rawUI) {
            validateUI(rawUI, path: "ui", issues: &issues)
        }
        if let rawNotifications = root["notifications"], !isNull(rawNotifications) {
            validateNotifications(rawNotifications, path: "notifications", issues: &issues)
        }
        if let rawAgentChat = root["agentChat"], !isNull(rawAgentChat) {
            validateAgentChat(rawAgentChat, path: "agentChat", issues: &issues)
        }
        if let rawNewWorkspaceCommand = root["newWorkspaceCommand"], !isNull(rawNewWorkspaceCommand) {
            validateNonBlankString(rawNewWorkspaceCommand, path: "newWorkspaceCommand", issues: &issues)
        }
        if let rawButtons = root["surfaceTabBarButtons"], !isNull(rawButtons) {
            validateSurfaceTabBarButtons(rawButtons, path: "surfaceTabBarButtons", issues: &issues)
        }
        if let rawCommands = root["commands"], !isNull(rawCommands) {
            validateCommands(rawCommands, path: "commands", issues: &issues)
        }
        if let rawVault = root["vault"], !isNull(rawVault) {
            validateVault(rawVault, path: "vault", issues: &issues)
        }
        if let rawWorkspaceGroups = root["workspaceGroups"], !isNull(rawWorkspaceGroups) {
            validateWorkspaceGroups(rawWorkspaceGroups, path: "workspaceGroups", issues: &issues)
        }
    }

    private func validateCommands(
        _ rawCommands: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let commands = rawCommands as? [Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("array", defaultValue: "an array")]))
            return
        }
        for (index, rawEntry) in commands.enumerated() {
            let entryPath = "\(path)[\(index)]"
            guard let entry = rawEntry as? [String: Any] else {
                issues.append(issue(path: entryPath, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                continue
            }
            validateEntry(entry, path: entryPath, issues: &issues)
        }
    }

    private func validateActions(
        _ rawActions: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let actions = rawActions as? [String: Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            return
        }
        for (id, rawAction) in actions {
            let actionPath = "\(path).\(id)"
            guard let action = rawAction as? [String: Any] else {
                issues.append(issue(path: actionPath, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                continue
            }
            validateAction(action, path: actionPath, issues: &issues)
        }
    }

    private func validateAction(
        _ action: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        for key in [
            "type", "builtin", "command", "commandName", "name", "agent", "args",
            "title", "subtitle", "description", "tooltip", "target",
        ] {
            validateOptionalString(action[key], path: "\(path).\(key)", issues: &issues)
        }
        for key in ["palette", "confirm", "newWorkspaceMenu"] {
            validateOptionalBoolean(action[key], path: "\(path).\(key)", issues: &issues)
        }
        if let rawKeywords = action["keywords"], !isNull(rawKeywords) {
            validateArrayOfStrings(rawKeywords, path: "\(path).keywords", issues: &issues)
        }
        if let rawRestart = action["restart"], !isNull(rawRestart) {
            guard let restart = rawRestart as? String,
                  ["new", "recreate", "ignore", "confirm"].contains(restart) else {
                issues.append(issue(path: "\(path).restart", key: "invalidValue", arguments: []))
                return
            }
        }
        if let rawShortcut = action["shortcut"], !isNull(rawShortcut) {
            if rawShortcut is String {
                // StoredShortcut accepts a string and validates its syntax in the app decoder.
            } else if let strokes = rawShortcut as? [Any] {
                if !(1...2).contains(strokes.count) || !strokes.allSatisfy({ $0 is String }) {
                    issues.append(issue(
                        path: "\(path).shortcut",
                        key: "invalidField",
                        arguments: [phrase("string", defaultValue: "a string") + " or an array of one or two strings"]
                    ))
                }
            } else {
                issues.append(issue(
                    path: "\(path).shortcut",
                    key: "invalidField",
                    arguments: [phrase("string", defaultValue: "a string") + " or an array of one or two strings"]
                ))
            }
        }
        if let rawWorkspace = action["workspace"], !isNull(rawWorkspace) {
            guard let workspace = rawWorkspace as? [String: Any] else {
                issues.append(issue(path: "\(path).workspace", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                return
            }
            validateWorkspace(workspace, path: "\(path).workspace", layoutMode: .strict, issues: &issues)
        }

        let inferredType = (action["type"] as? String)
            ?? (action["agent"] != nil ? "agent" : nil)
            ?? (action["builtin"] != nil ? "builtin" : nil)
            ?? (action["workspace"] != nil ? "workspace" : nil)
            ?? (action["command"] != nil ? "command" : nil)
        switch inferredType {
        case "builtin":
            validateNonBlankString(action["builtin"], path: "\(path).builtin", issues: &issues)
        case "command":
            validateNonBlankString(action["command"], path: "\(path).command", issues: &issues)
        case "agent":
            validateNonBlankString(action["agent"], path: "\(path).agent", issues: &issues)
        case "workspaceCommand":
            let commandName = action["commandName"] ?? action["name"] ?? action["command"]
            validateNonBlankString(commandName, path: "\(path).commandName", issues: &issues)
        case "workspace":
            guard action["workspace"] != nil, !isNull(action["workspace"]) else {
                issues.append(issue(path: path, key: "invalidValue", arguments: []))
                return
            }
        case nil:
            break
        default:
            issues.append(issue(path: "\(path).type", key: "invalidValue", arguments: []))
        }
    }

    private func validateUI(
        _ rawUI: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let ui = rawUI as? [String: Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            return
        }
        if let rawNewWorkspace = ui["newWorkspace"], !isNull(rawNewWorkspace) {
            validateButtonPlacement(rawNewWorkspace, path: "\(path).newWorkspace", issues: &issues)
        }
        if let rawSurfaceTabBar = ui["surfaceTabBar"], !isNull(rawSurfaceTabBar) {
            guard let surfaceTabBar = rawSurfaceTabBar as? [String: Any] else {
                issues.append(issue(path: "\(path).surfaceTabBar", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                return
            }
            if let rawButtons = surfaceTabBar["buttons"], !isNull(rawButtons) {
                validateSurfaceTabBarButtons(rawButtons, path: "\(path).surfaceTabBar.buttons", issues: &issues)
            }
        }
    }

    private func validateButtonPlacement(
        _ rawPlacement: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let placement = rawPlacement as? [String: Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            return
        }
        validateOptionalString(placement["action"], path: "\(path).action", issues: &issues)
        validateOptionalString(placement["tooltip"], path: "\(path).tooltip", issues: &issues)
        if let rawIcon = placement["icon"], !isNull(rawIcon) {
            validateIcon(rawIcon, path: "\(path).icon", issues: &issues)
        }
        let rawContextMenu = placement["contextMenu"] ?? placement["rightClick"]
        if let rawContextMenu, !isNull(rawContextMenu) {
            validateContextMenu(rawContextMenu, path: "\(path).contextMenu", issues: &issues)
        }
    }

    private func validateSurfaceTabBarButtons(
        _ rawButtons: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let buttons = rawButtons as? [Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("array", defaultValue: "an array")]))
            return
        }
        for (index, rawButton) in buttons.enumerated() {
            let buttonPath = "\(path)[\(index)]"
            if let button = rawButton as? String {
                validateNonBlankString(button, path: buttonPath, issues: &issues)
            } else if let button = rawButton as? [String: Any] {
                validateSurfaceTabBarButton(button, path: buttonPath, issues: &issues)
            } else {
                issues.append(issue(path: buttonPath, key: "invalidField", arguments: [phrase("string", defaultValue: "a string") + " or an object"]))
            }
        }
    }

    private func validateSurfaceTabBarButton(
        _ button: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        for key in ["id", "title", "tooltip", "action", "builtin", "command", "agent", "args", "type", "commandName", "name", "target"] {
            validateOptionalString(button[key], path: "\(path).\(key)", issues: &issues)
        }
        validateOptionalBoolean(button["confirm"], path: "\(path).confirm", issues: &issues)
        if let rawIcon = button["icon"], !isNull(rawIcon) {
            validateIcon(rawIcon, path: "\(path).icon", issues: &issues)
        }
        if let rawWorkspace = button["workspace"], !isNull(rawWorkspace) {
            guard let workspace = rawWorkspace as? [String: Any] else {
                issues.append(issue(path: "\(path).workspace", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                return
            }
            validateWorkspace(workspace, path: "\(path).workspace", layoutMode: .strict, issues: &issues)
        }
    }

    private func validateContextMenu(
        _ rawContextMenu: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let items = rawContextMenu as? [Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("array", defaultValue: "an array")]))
            return
        }
        for (index, rawItem) in items.enumerated() {
            let itemPath = "\(path)[\(index)]"
            if let item = rawItem as? String {
                validateNonBlankString(item, path: itemPath, issues: &issues)
            } else if let item = rawItem as? [String: Any] {
                if let rawType = item["type"], !isNull(rawType) {
                    validateOptionalString(rawType, path: "\(itemPath).type", issues: &issues)
                }
                validateNonBlankString(item["action"], path: "\(itemPath).action", issues: &issues)
                validateOptionalString(item["title"], path: "\(itemPath).title", issues: &issues)
                validateOptionalString(item["tooltip"], path: "\(itemPath).tooltip", issues: &issues)
                if let rawIcon = item["icon"], !isNull(rawIcon) {
                    validateIcon(rawIcon, path: "\(itemPath).icon", issues: &issues)
                }
            } else {
                issues.append(issue(path: itemPath, key: "invalidField", arguments: [phrase("string", defaultValue: "a string") + " or an object"]))
            }
        }
    }

    private func validateIcon(
        _ rawIcon: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let icon = rawIcon as? [String: Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            return
        }
        guard let type = icon["type"] as? String else {
            issues.append(issue(path: "\(path).type", key: "invalidField", arguments: [phrase("nonBlankString", defaultValue: "a non-blank string")]))
            return
        }
        switch type {
        case "symbol", "sfSymbol", "systemImage":
            validateNonBlankString(icon["name"], path: "\(path).name", issues: &issues)
        case "emoji":
            validateNonBlankString(icon["value"], path: "\(path).value", issues: &issues)
            if let rawScale = icon["scale"], !isNull(rawScale), !isJSONNumber(rawScale) {
                issues.append(issue(path: "\(path).scale", key: "invalidField", arguments: [phrase("number", defaultValue: "a number")]))
            }
        case "image", "file":
            validateNonBlankString(icon["path"], path: "\(path).path", issues: &issues)
        default:
            issues.append(issue(path: "\(path).type", key: "invalidValue", arguments: []))
        }
    }

    private func validateNotifications(
        _ rawNotifications: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let notifications = rawNotifications as? [String: Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            return
        }
        if let rawMode = notifications["hooksMode"], !isNull(rawMode),
           !((rawMode as? String).map(["append", "replace"].contains) ?? false) {
            issues.append(issue(path: "\(path).hooksMode", key: "invalidValue", arguments: []))
        }
        guard let rawHooks = notifications["hooks"], !isNull(rawHooks) else { return }
        guard let hooks = rawHooks as? [Any] else {
            issues.append(issue(path: "\(path).hooks", key: "invalidField", arguments: [phrase("array", defaultValue: "an array")]))
            return
        }
        for (index, rawHook) in hooks.enumerated() {
            let hookPath = "\(path).hooks[\(index)]"
            guard let hook = rawHook as? [String: Any] else {
                issues.append(issue(path: hookPath, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                continue
            }
            validateNonBlankString(hook["id"], path: "\(hookPath).id", issues: &issues)
            validateNonBlankString(hook["command"], path: "\(hookPath).command", issues: &issues)
            if let rawTimeout = hook["timeoutSeconds"], !isNull(rawTimeout), !isJSONNumber(rawTimeout) {
                issues.append(issue(path: "\(hookPath).timeoutSeconds", key: "invalidField", arguments: [phrase("number", defaultValue: "a number")]))
            }
            validateOptionalBoolean(hook["enabled"], path: "\(hookPath).enabled", issues: &issues)
        }
    }

    private func validateAgentChat(
        _ rawAgentChat: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let agentChat = rawAgentChat as? [String: Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            return
        }
        if let rawURL = agentChat["url"], !isNull(rawURL) {
            guard let url = rawURL as? String,
                  let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  components.host?.isEmpty == false else {
                issues.append(issue(path: "\(path).url", key: "invalidValue", arguments: []))
                return
            }
        }
        validateOptionalString(agentChat["startCommand"], path: "\(path).startCommand", issues: &issues)
    }

    private func validateVault(
        _ rawVault: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let vault = rawVault as? [String: Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            return
        }
        guard let rawAgents = vault["agents"], !isNull(rawAgents) else {
            issues.append(issue(path: "\(path).agents", key: "invalidField", arguments: [phrase("array", defaultValue: "an array")]))
            return
        }
        guard let agents = rawAgents as? [Any] else {
            issues.append(issue(path: "\(path).agents", key: "invalidField", arguments: [phrase("array", defaultValue: "an array")]))
            return
        }
        for (index, rawAgent) in agents.enumerated() {
            let agentPath = "\(path).agents[\(index)]"
            guard let agent = rawAgent as? [String: Any] else {
                issues.append(issue(path: agentPath, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                continue
            }
            validateNonBlankString(agent["id"], path: "\(agentPath).id", issues: &issues)
            validateNonBlankString(agent["name"], path: "\(agentPath).name", issues: &issues)
            validateNonBlankString(agent["resumeCommand"], path: "\(agentPath).resumeCommand", issues: &issues)
            validateOptionalString(agent["iconAssetName"], path: "\(agentPath).iconAssetName", issues: &issues)
            validateOptionalString(agent["forkCommand"], path: "\(agentPath).forkCommand", issues: &issues)
            validateOptionalString(agent["sessionDirectory"], path: "\(agentPath).sessionDirectory", issues: &issues)
            if let rawDetect = agent["detect"], !isNull(rawDetect) {
                guard let detect = rawDetect as? [String: Any] else {
                    issues.append(issue(path: "\(agentPath).detect", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                    continue
                }
                for key in ["processName", "processNames", "argvContains", "alternateProcessNames", "alternateArgvContains", "alternateArgvContainsAny", "alternateArgvBasenamesAny"] {
                    if let rawValue = detect[key], !isNull(rawValue) {
                        if rawValue is String {
                            continue
                        }
                        validateArrayOfStrings(rawValue, path: "\(agentPath).detect.\(key)", issues: &issues)
                    }
                }
            } else {
                issues.append(issue(path: "\(agentPath).detect", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            }
            if let rawSessionSource = agent["sessionIdSource"], !isNull(rawSessionSource) {
                guard rawSessionSource is String || rawSessionSource is [String: Any] else {
                    issues.append(issue(path: "\(agentPath).sessionIdSource", key: "invalidField", arguments: [phrase("string", defaultValue: "a string") + " or an object"]))
                    continue
                }
            } else {
                issues.append(issue(path: "\(agentPath).sessionIdSource", key: "invalidField", arguments: [phrase("nonBlankString", defaultValue: "a non-blank string")]))
            }
            guard let rawCWD = agent["cwd"], !isNull(rawCWD) else {
                issues.append(issue(path: "\(agentPath).cwd", key: "invalidField", arguments: [phrase("string", defaultValue: "a string")]))
                continue
            }
            guard let cwd = rawCWD as? String, ["preserve", "ignore", "none"].contains(cwd) else {
                issues.append(issue(path: "\(agentPath).cwd", key: "invalidValue", arguments: []))
                continue
            }
        }
    }

    private func validateWorkspaceGroups(
        _ rawWorkspaceGroups: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let workspaceGroups = rawWorkspaceGroups as? [String: Any] else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            return
        }
        guard let rawByCWD = workspaceGroups["byCwd"], !isNull(rawByCWD) else { return }
        guard let byCWD = rawByCWD as? [String: Any] else {
            issues.append(issue(path: "\(path).byCwd", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
            return
        }
        for (cwd, rawEntry) in byCWD {
            let entryPath = "\(path).byCwd.\(cwd)"
            guard let entry = rawEntry as? [String: Any] else {
                issues.append(issue(path: entryPath, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                continue
            }
            validateOptionalString(entry["color"], path: "\(entryPath).color", issues: &issues)
            validateOptionalString(entry["icon"], path: "\(entryPath).icon", issues: &issues)
            if let rawPlacement = entry["newWorkspacePlacement"], !isNull(rawPlacement) {
                guard let placement = rawPlacement as? String,
                      ["afterCurrent", "top", "end"].contains(placement) else {
                    issues.append(issue(path: "\(entryPath).newWorkspacePlacement", key: "invalidValue", arguments: []))
                    continue
                }
            }
            if let rawContextMenu = entry["contextMenu"], !isNull(rawContextMenu) {
                validateContextMenu(rawContextMenu, path: "\(entryPath).contextMenu", issues: &issues)
            }
        }
    }

    private func validateOptionalString(
        _ value: Any?,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let value, !isNull(value) else { return }
        guard value is String else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("string", defaultValue: "a string")]))
            return
        }
    }

    private func validateNonBlankString(
        _ value: Any?,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let value, !isNull(value), let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("nonBlankString", defaultValue: "a non-blank string")]))
            return
        }
    }

    private func validateOptionalBoolean(
        _ value: Any?,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let value, !isNull(value) else { return }
        guard isJSONBoolean(value) else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("boolean", defaultValue: "a boolean")]))
            return
        }
    }

    private func validateArrayOfStrings(
        _ value: Any,
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let values = value as? [Any], values.allSatisfy({ $0 is String }) else {
            issues.append(issue(path: path, key: "invalidField", arguments: [phrase("arrayOfStrings", defaultValue: "an array of strings")]))
            return
        }
    }

    func issues(in data: Data) throws -> [CmuxConfigTypeIssue] {
        let object = try JSONSerialization.jsonObject(with: data)
        return issues(in: object)
    }

    private func validateEntry(
        _ entry: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let name = entry["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues.append(issue(path: "\(path).name", key: "invalidField", arguments: [phrase("nonBlankString", defaultValue: "a non-blank string")]))
            return
        }

        validateCommonFields(entry, path: path, issues: &issues)

        if let rawCommand = entry["command"], !isNull(rawCommand) {
            guard let command = rawCommand as? String,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues.append(issue(path: "\(path).command", key: "invalidField", arguments: [phrase("nonBlankString", defaultValue: "a non-blank string")]))
                return
            }
            // `command` is the discriminator. A mixed entry may carry stale
            // layout metadata; the runtime decoder deliberately ignores it.
            _ = command
            return
        }

        if let rawWorkspace = entry["workspace"], !isNull(rawWorkspace) {
            guard let workspace = rawWorkspace as? [String: Any] else {
                issues.append(issue(path: "\(path).workspace", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                return
            }
            validateWorkspace(
                workspace,
                path: "\(path).workspace",
                layoutMode: .strict,
                issues: &issues
            )
            return
        }

        let flattenedWorkspaceKeys = ["cwd", "color", "env", "setup", "layout"]
        guard flattenedWorkspaceKeys.contains(where: { key in
            guard let value = entry[key] else { return false }
            return !isNull(value)
        }) else {
            issues.append(issue(path: path, key: "missingDefinition", arguments: []))
            return
        }
        validateWorkspace(entry, path: path, layoutMode: .legacyFlattenedRoot, issues: &issues)
    }

    private func validateCommonFields(
        _ entry: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        if let value = entry["description"], !isNull(value), !(value is String) {
            issues.append(issue(path: "\(path).description", key: "invalidField", arguments: [phrase("string", defaultValue: "a string")]))
        }
        if let value = entry["keywords"], !isNull(value) {
            if !((value as? [Any])?.allSatisfy({ $0 is String }) ?? false) {
                issues.append(issue(path: "\(path).keywords", key: "invalidField", arguments: [phrase("arrayOfStrings", defaultValue: "an array of strings")]))
            }
        }
        if let value = entry["restart"], !isNull(value) {
            let allowed = ["new", "recreate", "ignore", "confirm"]
            if !((value as? String).map(allowed.contains) ?? false) {
                issues.append(issue(path: "\(path).restart", key: "invalidValue", arguments: []))
            }
        }
        if let value = entry["confirm"], !isNull(value), !isJSONBoolean(value) {
            issues.append(issue(path: "\(path).confirm", key: "invalidField", arguments: [phrase("boolean", defaultValue: "a boolean")]))
        }
    }

    private func validateWorkspace(
        _ workspace: [String: Any],
        path: String,
        layoutMode: CmuxLayoutDecodingMode,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        for key in ["name", "cwd", "setup"] {
            if let value = workspace[key], !isNull(value), !(value is String) {
                issues.append(issue(path: "\(path).\(key)", key: "invalidField", arguments: [phrase("string", defaultValue: "a string")]))
            }
        }
        if let value = workspace["color"], !isNull(value) {
            guard let color = value as? String else {
                issues.append(issue(path: "\(path).color", key: "invalidField", arguments: [phrase("nonBlankString", defaultValue: "a non-blank string")]))
                return
            }
            let normalizedColor = color.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedColor.isEmpty else {
                issues.append(issue(path: "\(path).color", key: "invalidField", arguments: [phrase("nonBlankString", defaultValue: "a non-blank string")]))
                return
            }
            if !Self.isSixDigitHexColor(normalizedColor), !workspaceColorNames.contains(normalizedColor.lowercased()) {
                issues.append(issue(
                    path: "\(path).color",
                    key: "invalidColor",
                    arguments: [CmuxConfigTypeIssue.sanitizeText(normalizedColor, replacingNewlines: true)]
                ))
            }
        }
        if let value = workspace["env"], !isNull(value) {
            if !((value as? [String: Any])?.values.allSatisfy({ $0 is String }) ?? false) {
                issues.append(issue(path: "\(path).env", key: "invalidField", arguments: [phrase("objectOfStrings", defaultValue: "an object of strings")]))
            }
        }
        if let value = workspace["layout"], !isNull(value) {
            guard let layout = value as? [String: Any] else {
                issues.append(issue(path: "\(path).layout", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                return
            }
            validateLayout(
                layout,
                path: "\(path).layout",
                allowsLegacySingleChildSplit: layoutMode.allowsLegacySingleChildSplit,
                issues: &issues
            )
        }
    }

    private func validateLayout(
        _ node: [String: Any],
        path: String,
        allowsLegacySingleChildSplit: Bool,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        let hasPane = node.keys.contains("pane")
        let hasDirection = node.keys.contains("direction")
        guard !(hasPane && hasDirection) else {
            issues.append(issue(path: path, key: "invalidValue", arguments: []))
            return
        }

        if hasPane {
            guard let rawPane = node["pane"] as? [String: Any] else {
                issues.append(issue(path: "\(path).pane", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                return
            }
            validatePane(rawPane, path: "\(path).pane", issues: &issues)
            return
        }

        guard hasDirection else {
            issues.append(issue(path: path, key: "invalidValue", arguments: []))
            return
        }
        guard let direction = node["direction"] as? String,
              direction == "horizontal" || direction == "vertical" else {
            issues.append(issue(path: "\(path).direction", key: "invalidValue", arguments: []))
            return
        }
        if let value = node["split"], !isNull(value), !isJSONNumber(value) {
            issues.append(issue(path: "\(path).split", key: "invalidField", arguments: [phrase("number", defaultValue: "a number")]))
        }
        guard let rawChildren = node["children"] as? [Any] else {
            issues.append(issue(path: "\(path).children", key: "invalidField", arguments: [phrase("array", defaultValue: "an array")]))
            return
        }
        guard rawChildren.count == 2 || (allowsLegacySingleChildSplit && rawChildren.count == 1) else {
            issues.append(issue(
                path: "\(path).children",
                key: "invalidCount",
                arguments: [phrase(
                    allowsLegacySingleChildSplit ? "oneOrTwo" : "two",
                    defaultValue: allowsLegacySingleChildSplit ? "1 or 2" : "2"
                )]
            ))
            return
        }
        for (index, rawChild) in rawChildren.enumerated() {
            guard let child = rawChild as? [String: Any] else {
                issues.append(issue(path: "\(path).children[\(index)]", key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                continue
            }
            validateLayout(
                child,
                path: "\(path).children[\(index)]",
                allowsLegacySingleChildSplit: false,
                issues: &issues
            )
        }
    }

    private func validatePane(
        _ pane: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let rawSurfaces = pane["surfaces"] as? [Any] else {
            issues.append(issue(path: "\(path).surfaces", key: "invalidField", arguments: [phrase("array", defaultValue: "an array")]))
            return
        }
        guard !rawSurfaces.isEmpty else {
            issues.append(issue(path: "\(path).surfaces", key: "invalidCount", arguments: [phrase("atLeastOne", defaultValue: "at least 1")]))
            return
        }
        for (index, rawSurface) in rawSurfaces.enumerated() {
            let surfacePath = "\(path).surfaces[\(index)]"
            guard let surface = rawSurface as? [String: Any] else {
                issues.append(issue(path: surfacePath, key: "invalidField", arguments: [phrase("object", defaultValue: "an object")]))
                continue
            }
            guard let type = surface["type"] as? String,
                  ["terminal", "browser", "project"].contains(type) else {
                issues.append(issue(path: "\(surfacePath).type", key: "invalidValue", arguments: []))
                continue
            }
            for key in ["name", "command", "cwd", "url"] {
                if let value = surface[key], !isNull(value), !(value is String) {
                    issues.append(issue(path: "\(surfacePath).\(key)", key: "invalidField", arguments: [phrase("string", defaultValue: "a string")]))
                }
            }
            if let value = surface["env"], !isNull(value) {
                guard let environment = value as? [String: Any],
                      environment.values.allSatisfy({ $0 is String }) else {
                    issues.append(issue(path: "\(surfacePath).env", key: "invalidField", arguments: [phrase("objectOfStrings", defaultValue: "an object of strings")]))
                    continue
                }
            }
            if let value = surface["focus"], !isNull(value), !isJSONBoolean(value) {
                issues.append(issue(path: "\(surfacePath).focus", key: "invalidField", arguments: [phrase("boolean", defaultValue: "a boolean")]))
            }
        }
    }

    private static func isSixDigitHexColor(_ value: String) -> Bool {
        let body = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = body.hasPrefix("#") ? body.dropFirst() : body[...]
        let scalars = Array(digits.unicodeScalars)
        guard scalars.count == 6 else { return false }
        return scalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 70)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private static func normalizedHexColor(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSixDigitHexColor(trimmed) else { return nil }
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        return "#" + digits.uppercased()
    }

    private func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private func isJSONNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        return type != "c" && type != "B"
    }

    private func isJSONBoolean(_ value: Any) -> Bool {
        // JSONSerialization bridges both booleans and numbers to NSNumber;
        // objCType is the reliable discriminator for JSON's strict Bool type.
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
    }

    private func phrase(_ key: String, defaultValue: String) -> String {
        switch key {
        case "array":
            return String(localized: "config.validation.type.array", defaultValue: "an array")
        case "arrayOfStrings":
            return String(localized: "config.validation.type.arrayOfStrings", defaultValue: "an array of strings")
        case "atLeastOne":
            return String(localized: "config.validation.type.atLeastOne", defaultValue: "at least 1")
        case "boolean":
            return String(localized: "config.validation.type.boolean", defaultValue: "a boolean")
        case "nonBlankString":
            return String(localized: "config.validation.type.nonBlankString", defaultValue: "a non-blank string")
        case "number":
            return String(localized: "config.validation.type.number", defaultValue: "a number")
        case "object":
            return String(localized: "config.validation.type.object", defaultValue: "an object")
        case "objectOfStrings":
            return String(localized: "config.validation.type.objectOfStrings", defaultValue: "an object of strings")
        case "oneOrTwo":
            return String(localized: "config.validation.type.oneOrTwo", defaultValue: "1 or 2")
        case "string":
            return String(localized: "config.validation.type.string", defaultValue: "a string")
        case "two":
            return String(localized: "config.validation.type.two", defaultValue: "2")
        default:
            return defaultValue
        }
    }

    private func issue(path: String, key: String, arguments: [String]) -> CmuxConfigTypeIssue {
        let localized: String
        switch key {
        case "missingDefinition":
            localized = String(
                localized: "config.validation.missingDefinition",
                defaultValue: "must define either 'command' or a workspace layout"
            )
        case "invalidValue":
            localized = String(
                localized: "config.validation.invalidValue",
                defaultValue: "has an invalid value"
            )
        case "invalidColor":
            localized = String(
                localized: "config.validation.invalidColor",
                defaultValue: "Invalid color \"%@\". Expected 6-digit hex format (#RRGGBB) or a workspace color name"
            )
        case "invalidCount":
            localized = String(
                localized: "config.validation.invalidCount",
                defaultValue: "must contain the required number of entries (%@)"
            )
        default:
            localized = String(
                localized: "config.validation.invalidField",
                defaultValue: "must be %@"
            )
        }
        let cvarArguments: [CVarArg] = arguments.map { $0 as NSString }
        return CmuxConfigTypeIssue(
            path: path,
            message: String(format: localized, arguments: cvarArguments)
        )
    }
}
