import Foundation

/// Cursor state for the compatibility snapshot API. The typed `CloudVMState` path is the
/// normal provider boundary; this small state keeps older callers from regressing an accepted
/// graph while they migrate to that path.
struct CloudResourceCompatibilityState {
    var cursor: CloudVMCursor
    var canonicalWorkspaces: [SurfaceRemoteWorkspace]
    var acceptedGenerations: Set<String>
}

struct CloudWorkspaceRenameKey: Hashable, Sendable {
    let machine: SurfaceMachineID
    let workspaceID: String
}

struct CloudWorkspaceRenameIntent {
    let tokenID: UUID
    let baseName: String
    let name: String
    var receipt: CloudVMCursor?
}

struct CloudWorkspaceRenameToken: Hashable, Sendable {
    let id: UUID
    let key: CloudWorkspaceRenameKey
}

extension SurfaceCatalog {
    /// Replaces a cloud machine's legacy resource rows only when the cursor is current. Equal
    /// cursors are treated as no-ops unless they carry the exact name covered by a read-your-write
    /// receipt; all other equal and older snapshots are stale.
    @discardableResult
    func replaceCloudResources(
        _ list: [SurfaceResource],
        on machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        cursor: CloudVMCursor
    ) -> Bool {
        guard case .cloud = machine,
              info.id == machine,
              accepts(writeFor: machine) else { return false }
        for resource in list {
            precondition(resource.machine == machine, "resource \(resource.id) reported by the wrong cloud machine")
        }
        guard acceptsCloudCompatibilitySnapshot(list, info: info, machine: machine, cursor: cursor) else {
            return false
        }

        let previous = cloudResourceCompatibility[machine]
        var generations = previous?.acceptedGenerations ?? []
        generations.insert(cursor.generation)
        cloudResourceCompatibility[machine] = CloudResourceCompatibilityState(
            cursor: cursor,
            canonicalWorkspaces: info.remoteWorkspaces ?? [],
            acceptedGenerations: generations
        )

        retireCloudWorkspaceRenameIntents(observed: info.remoteWorkspaces ?? [], cursor: cursor, machine: machine)
        let effectiveInfo = cloudResourceCompatibilityMachineInfo(info)
        let effectiveResources = cloudWorkspaceRenameEffectiveResources(list, machine: machine)
        return replaceResources(effectiveResources, on: machine, info: effectiveInfo)
    }

    /// Begins an optimistic workspace rename and returns a token that can later be committed or
    /// rolled back. Multiple tokens for one identity retain the original base name, so an older
    /// completion can never undo a newer intent.
    func beginCloudWorkspaceRename(
        machine: SurfaceMachineID,
        workspaceID: String,
        name: String
    ) throws -> CloudWorkspaceRenameToken {
        guard case .cloud = machine,
              accepts(writeFor: machine) else { throw SurfaceCatalogError.noProvider(machine) }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SurfaceCatalogError.unsupported("cloud workspace names cannot be empty")
        }
        let key = CloudWorkspaceRenameKey(machine: machine, workspaceID: workspaceID)
        guard let machineInfo = snapshot.machines.first(where: { $0.id == machine }),
              let workspace = machineInfo.remoteWorkspaces?.first(where: { $0.id == workspaceID }) else {
            throw SurfaceCatalogError.destinationNotFound("workspace \(workspaceID) on \(machine.rawValue)")
        }
        let intents = cloudWorkspaceRenameIntents[key] ?? []
        let baseName = intents.first?.baseName ?? workspace.name
        let token = CloudWorkspaceRenameToken(id: UUID(), key: key)
        cloudWorkspaceRenameIntents[key, default: []].append(
            CloudWorkspaceRenameIntent(
                tokenID: token.id,
                baseName: baseName,
                name: normalizedName,
                receipt: nil
            )
        )
        applyCloudWorkspaceRenameOverlay(machine: machine)
        return token
    }

    /// Records the daemon's read-your-write cursor. The intent remains visible until an
    /// accepted snapshot reaches that cursor and proves the requested workspace name.
    func commitCloudWorkspaceRename(_ token: CloudWorkspaceRenameToken, receipt: CloudVMCursor) {
        guard var intents = cloudWorkspaceRenameIntents[token.key],
              let index = intents.firstIndex(where: { $0.tokenID == token.id }) else { return }
        intents[index].receipt = receipt
        cloudWorkspaceRenameIntents[token.key] = intents
    }

    /// Removes one optimistic intent. If a newer intent remains, its name stays projected; when
    /// the final intent is removed, the catalog returns to the accepted canonical workspace name.
    func rollbackCloudWorkspaceRename(_ token: CloudWorkspaceRenameToken) {
        guard var intents = cloudWorkspaceRenameIntents[token.key],
              let index = intents.firstIndex(where: { $0.tokenID == token.id }) else { return }
        intents.remove(at: index)
        if intents.isEmpty {
            cloudWorkspaceRenameIntents[token.key] = nil
        } else {
            cloudWorkspaceRenameIntents[token.key] = intents
        }
        applyCloudWorkspaceRenameOverlay(machine: token.key.machine)
    }

    func pendingCloudWorkspaceRenameName(machine: SurfaceMachineID, workspaceID: String) -> String? {
        cloudWorkspaceRenameIntents[CloudWorkspaceRenameKey(machine: machine, workspaceID: workspaceID)]?.last?.name
    }

    /// Called by `SurfaceCatalog`'s existing cursorless machine-update path. It preserves the
    /// last accepted workspace graph while still exposing the newest local optimistic name.
    func cloudResourceCompatibilityMachineInfo(_ info: SurfaceMachineInfo) -> SurfaceMachineInfo {
        guard let state = cloudResourceCompatibility[info.id] else { return info }
        var adjusted = info
        var workspaces = state.canonicalWorkspaces
        for (index, workspace) in workspaces.enumerated() {
            let key = CloudWorkspaceRenameKey(machine: info.id, workspaceID: workspace.id)
            if let name = cloudWorkspaceRenameIntents[key]?.last?.name {
                workspaces[index].name = name
            }
        }
        adjusted.remoteWorkspaces = workspaces
        return adjusted
    }

    private func acceptsCloudCompatibilitySnapshot(
        _ list: [SurfaceResource],
        info: SurfaceMachineInfo,
        machine: SurfaceMachineID,
        cursor: CloudVMCursor
    ) -> Bool {
        guard let current = cloudResourceCompatibility[machine] else { return true }
        if cursor.generation != current.cursor.generation {
            return !current.acceptedGenerations.contains(cursor.generation)
        }
        if cursor.revision < current.cursor.revision { return false }
        var matchedReceiptAtCursor = false
        for (key, intents) in cloudWorkspaceRenameIntents where key.machine == machine {
            for intent in intents {
                guard let receipt = intent.receipt, receipt.generation == cursor.generation else { continue }
                if cursor.revision < receipt.revision { return false }
                if cursor.revision == receipt.revision,
                   info.remoteWorkspaces?.first(where: { $0.id == key.workspaceID })?.name != intent.name {
                    return false
                }
                if cursor.revision == receipt.revision {
                    matchedReceiptAtCursor = true
                }
            }
        }
        if cursor.revision > current.cursor.revision { return true }
        return matchedReceiptAtCursor ? true : false
    }

    private func retireCloudWorkspaceRenameIntents(
        observed workspaces: [SurfaceRemoteWorkspace],
        cursor: CloudVMCursor,
        machine: SurfaceMachineID
    ) {
        for (key, intents) in cloudWorkspaceRenameIntents where key.machine == machine {
            let observedName = workspaces.first(where: { $0.id == key.workspaceID })?.name
            let remaining = intents.filter { intent in
                guard let receipt = intent.receipt else { return true }
                if cursor.generation != receipt.generation { return false }
                if cursor.revision > receipt.revision { return false }
                if cursor.revision == receipt.revision && observedName == intent.name { return false }
                return true
            }
            cloudWorkspaceRenameIntents[key] = remaining.isEmpty ? nil : remaining
        }
    }

    private func applyCloudWorkspaceRenameOverlay(machine: SurfaceMachineID) {
        guard let info = snapshot.machines.first(where: { $0.id == machine }) else { return }
        let effectiveInfo = cloudResourceCompatibilityMachineInfo(info)
        let effectiveResources = cloudWorkspaceRenameEffectiveResources(snapshot.resources(on: machine), machine: machine)
        _ = replaceResources(effectiveResources, on: machine, info: effectiveInfo)
    }

    private func cloudWorkspaceRenameEffectiveResources(
        _ resources: [SurfaceResource],
        machine: SurfaceMachineID
    ) -> [SurfaceResource] {
        resources.map { resource in
            guard resource.machine == machine else { return resource }
            var adjusted = resource
            if let workspace = adjusted.remoteWorkspace {
                let key = CloudWorkspaceRenameKey(machine: machine, workspaceID: workspace.id)
                if let name = cloudWorkspaceRenameIntents[key]?.last?.name {
                    adjusted.remoteWorkspace?.name = name
                }
            }
            adjusted.remoteViews = adjusted.remoteViews?.map { view in
                let key = CloudWorkspaceRenameKey(machine: machine, workspaceID: view.workspace.id)
                guard let name = cloudWorkspaceRenameIntents[key]?.last?.name else { return view }
                var adjustedView = view
                adjustedView.workspace.name = name
                return adjustedView
            }
            return adjusted
        }
    }
}
