public import Foundation
import JavaScriptCore

/// Immutable workspace metadata passed to `orderWorkspaces` in
/// `~/.config/cmux/sidebar-order.js`.
public struct SidebarWorkspaceSortScriptInput: Hashable, Sendable {
    /// Stable workspace identity.
    public let id: UUID
    /// Current display title.
    public let title: String
    /// Zero-based position in the persisted manual order.
    public let manualIndex: Int
    /// Stable creation time, restored across app launches.
    public let createdAt: Date
    /// Whether this is the selected workspace.
    public let isSelected: Bool
    /// Whether this ungrouped workspace is pinned.
    public let isPinned: Bool
    /// Effective workspace group identity, when present.
    public let groupId: UUID?
    /// Current displayed directory.
    public let directory: String
    /// First displayed Git branch, when present.
    public let gitBranch: String?
    /// Whether the displayed Git branch has uncommitted changes.
    public let gitIsDirty: Bool

    /// Creates one custom ordering input.
    public init(
        id: UUID,
        title: String,
        manualIndex: Int,
        createdAt: Date,
        isSelected: Bool,
        isPinned: Bool,
        groupId: UUID?,
        directory: String,
        gitBranch: String?,
        gitIsDirty: Bool
    ) {
        self.id = id
        self.title = title
        self.manualIndex = manualIndex
        self.createdAt = createdAt
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.groupId = groupId
        self.directory = directory
        self.gitBranch = gitBranch
        self.gitIsDirty = gitIsDirty
    }
}

/// A custom workspace-order script validation or execution failure.
public struct SidebarWorkspaceSortScriptError: Error, Equatable, LocalizedError, Sendable {
    /// Human-readable failure detail suitable for the sidebar error row.
    public let message: String

    /// Creates a script failure with a concise message.
    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Evaluates the custom default-sidebar ordering function in a contained
/// JavaScriptCore context with no host capabilities.
public enum SidebarWorkspaceSortScriptEvaluator {
    private static let executionTimeLimit = 0.05

    /// Runs `orderWorkspaces(workspaces)` and returns its ordered workspace ids.
    ///
    /// The function may return workspace objects from the supplied array or id
    /// strings. It may omit workspaces, which the caller appends in manual
    /// order. Unknown and duplicate ids are rejected.
    public nonisolated static func evaluate(
        source: String,
        workspaces: [SidebarWorkspaceSortScriptInput]
    ) -> Result<[UUID], SidebarWorkspaceSortScriptError> {
        guard let context = JSContext() else {
            return .failure(.init(message: "JavaScriptCore context could not be created."))
        }
        guard JSWatchdog.install(on: context, seconds: executionTimeLimit) else {
            return .failure(.init(message: "The JavaScript execution limit is unavailable."))
        }

        final class ErrorBox: @unchecked Sendable {
            var message: String?
        }
        let errors = ErrorBox()
        context.exceptionHandler = { _, exception in
            guard errors.message == nil else { return }
            let text = exception?.toString() ?? "unknown error"
            let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
            errors.message = line > 0 ? "line \(line): \(text)" : text
        }

        context.evaluateScript(
            source,
            withSourceURL: URL(fileURLWithPath: "~/.config/cmux/sidebar-order.js")
        )
        if let message = errors.message {
            return .failure(.init(message: message))
        }
        guard let function = context.objectForKeyedSubscript("orderWorkspaces"),
              !function.isUndefined,
              !function.isNull else {
            return .failure(.init(message: "Define function orderWorkspaces(workspaces)."))
        }
        guard let json = inputJSONString(workspaces),
              let jsonAPI = context.objectForKeyedSubscript("JSON"),
              let input = jsonAPI.invokeMethod("parse", withArguments: [json]) else {
            return .failure(.init(message: "Workspace metadata could not be encoded."))
        }
        context.setObject(input, forKeyedSubscript: "__cmuxWorkspaceOrderInput" as NSString)
        context.evaluateScript(
            "__cmuxWorkspaceOrderInput.forEach(Object.freeze); Object.freeze(__cmuxWorkspaceOrderInput);"
        )
        if let message = errors.message {
            return .failure(.init(message: message))
        }

        guard let output = function.call(withArguments: [input]) else {
            return .failure(.init(message: "orderWorkspaces returned no value."))
        }
        if let message = errors.message {
            return .failure(.init(message: message))
        }
        guard output.isArray, let values = output.toArray() else {
            return .failure(.init(message: "orderWorkspaces must return an array."))
        }

        let knownIds = Set(workspaces.map(\.id))
        var seen = Set<UUID>()
        var orderedIds: [UUID] = []
        orderedIds.reserveCapacity(values.count)
        for value in values {
            let rawId: String?
            if let string = value as? String {
                rawId = string
            } else if let object = value as? [String: Any] {
                rawId = object["id"] as? String
            } else if let object = value as? NSDictionary {
                rawId = object["id"] as? String
            } else {
                rawId = nil
            }
            guard let rawId, let id = UUID(uuidString: rawId) else {
                return .failure(.init(message: "Every returned item must be a workspace or workspace id."))
            }
            guard knownIds.contains(id) else {
                return .failure(.init(message: "The script returned an unknown workspace id: \(rawId)."))
            }
            guard seen.insert(id).inserted else {
                return .failure(.init(message: "The script returned a workspace more than once: \(rawId)."))
            }
            orderedIds.append(id)
        }
        return .success(orderedIds)
    }

    private nonisolated static func inputJSONString(
        _ workspaces: [SidebarWorkspaceSortScriptInput]
    ) -> String? {
        let objects: [[String: Any]] = workspaces.map { workspace in
            var object: [String: Any] = [
                "id": workspace.id.uuidString,
                "title": workspace.title,
                "manualIndex": workspace.manualIndex,
                "createdAt": Int(workspace.createdAt.timeIntervalSince1970 * 1_000),
                "selected": workspace.isSelected,
                "pinned": workspace.isPinned,
                "directory": workspace.directory,
                "dirty": workspace.gitIsDirty,
            ]
            if let groupId = workspace.groupId {
                object["groupId"] = groupId.uuidString
            }
            if let gitBranch = workspace.gitBranch {
                object["branch"] = gitBranch
            }
            return object
        }
        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(withJSONObject: objects),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
