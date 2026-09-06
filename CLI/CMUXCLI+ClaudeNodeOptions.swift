import Darwin
import Foundation

extension CMUXCLI {
    private static let claudeNodeOptionsRestoreModule = """
    const hadOriginalNodeOptions = process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT === "1";
    if (hadOriginalNodeOptions) {
      process.env.NODE_OPTIONS = process.env.CMUX_ORIGINAL_NODE_OPTIONS ?? "";
    } else {
      delete process.env.NODE_OPTIONS;
    }
    delete process.env.CMUX_ORIGINAL_NODE_OPTIONS;
    delete process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT;
    """ + "\n"

    private struct ClaudeNodeOptionsCachePathError: LocalizedError {
        let reason: String
        let path: String

        var errorDescription: String? {
            "Claude NODE_OPTIONS restore module \(reason): \(path)"
        }
    }

    private struct CachePathState {
        let owner: uid_t
        let isSymbolicLink: Bool
    }

    private static let unsafeNodeOptionsPathCharacters = CharacterSet(charactersIn: "\\\"'")

    private static func nodeOptionsPathIsSafe(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.rangeOfCharacter(from: unsafeNodeOptionsPathCharacters) == nil
    }

    private static func unquoteNodeOptionsPath(_ path: String) -> String {
        guard path.count >= 2,
              let first = path.first,
              let last = path.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return path
        }
        return String(path.dropFirst().dropLast())
    }

    private static func cachePathState(at url: URL) throws -> CachePathState? {
        var statValue = stat()
        guard lstat(url.path, &statValue) == 0 else {
            guard errno == ENOENT else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: url.path]
                )
            }
            return nil
        }
        return CachePathState(
            owner: statValue.st_uid,
            isSymbolicLink: (statValue.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
        )
    }

    private static func validateCachePath(_ url: URL, expectedOwner: uid_t) throws {
        guard let state = try cachePathState(at: url) else { return }
        guard !state.isSymbolicLink else {
            throw ClaudeNodeOptionsCachePathError(reason: "cache path is a symlink", path: url.path)
        }
        guard state.owner == expectedOwner else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "cache path is owned by a different uid",
                path: url.path
            )
        }
    }

    private static func claudeNodeOptionsRestoreModuleRoot() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["HOME"], !home.isEmpty else {
            throw ClaudeNodeOptionsCachePathError(reason: "HOME is unavailable", path: "")
        }
        let root = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("cmux-claude-node-options", isDirectory: true)
        guard nodeOptionsPathIsSafe(root.path) else {
            throw ClaudeNodeOptionsCachePathError(reason: "path is unsafe for --require", path: root.path)
        }
        return root
    }

    private func nodeOptionsRequirePaths(_ existing: String) -> [String] {
        let tokens = existing.split(whereSeparator: \.isWhitespace).map(String.init)
        var paths: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--require" || token == "-r" {
                if index + 1 < tokens.count {
                    paths.append(Self.unquoteNodeOptionsPath(tokens[index + 1]))
                    index += 2
                    continue
                }
            } else if token.hasPrefix("--require=") {
                paths.append(Self.unquoteNodeOptionsPath(String(token.dropFirst("--require=".count))))
            } else if token.hasPrefix("-r=") {
                paths.append(Self.unquoteNodeOptionsPath(String(token.dropFirst("-r=".count))))
            }
            index += 1
        }
        return paths
    }

    private func recreateLegacyNodeOptionsRestoreModules(excluding currentURL: URL) {
        guard let existing = ProcessInfo.processInfo.environment["NODE_OPTIONS"] else { return }
        let legacySuffix = "/cmux-claude-node-options/restore-node-options.cjs"
        for path in nodeOptionsRequirePaths(existing) {
            guard path.hasSuffix(legacySuffix),
                  Self.nodeOptionsPathIsSafe(path),
                  path != currentURL.path else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: false)
            let directory = url.deletingLastPathComponent()
            do {
                if try Self.cachePathState(at: directory)?.isSymbolicLink == true { continue }
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                try writeShimIfChanged(Self.claudeNodeOptionsRestoreModule, to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                continue
            }
        }
    }

    func createClaudeNodeOptionsRestoreModule() throws -> URL {
        let root = try Self.claudeNodeOptionsRestoreModuleRoot()
        try Self.validateCachePath(root, expectedOwner: getuid())
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.validateCachePath(root, expectedOwner: getuid())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let restoreModuleURL = root.appendingPathComponent("restore-node-options.cjs", isDirectory: false)
        try writeShimIfChanged(Self.claudeNodeOptionsRestoreModule, to: restoreModuleURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restoreModuleURL.path)
        recreateLegacyNodeOptionsRestoreModules(excluding: restoreModuleURL)
        return restoreModuleURL
    }

    func mergedNodeOptions(existing: String?, restoreModulePath: String) -> String {
        let escapedPath = restoreModulePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let requireOption = "--require=\"\(escapedPath)\""
        let memoryOption = "--max-old-space-size=4096"
        let cleanedExisting = cleanedNodeOptions(existing)
        guard !cleanedExisting.isEmpty else {
            return "\(requireOption) \(memoryOption)"
        }
        return "\(requireOption) \(memoryOption) \(cleanedExisting)"
    }

    private func cleanedNodeOptions(_ existing: String?) -> String {
        let tokens = (existing ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return "" }

        var filtered: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--max-old-space-size" {
                index += min(2, tokens.count - index)
                continue
            }
            if token.hasPrefix("--max-old-space-size=") {
                index += 1
                continue
            }
            filtered.append(token)
            index += 1
        }
        return filtered.joined(separator: " ")
    }

    func normalizedNodeOptionsForRestore(_ existing: String) -> String {
        let tokens = existing.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return "" }

        var normalized: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--max-old-space-size", index + 1 < tokens.count {
                normalized.append("--max-old-space-size=\(tokens[index + 1])")
                index += 2
                continue
            }
            normalized.append(token)
            index += 1
        }
        return normalized.joined(separator: " ")
    }
}
