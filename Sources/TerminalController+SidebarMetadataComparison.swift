import Foundation
import CmuxSidebar


extension TerminalController {
    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat
    ) -> Bool {
        guard let current else { return true }
        return current.key != key ||
            current.value != value ||
            current.icon != icon ||
            current.color != color ||
            current.url != url ||
            current.priority != priority ||
            current.format != format
    }

    nonisolated static func shouldReplaceMetadataBlock(
        current: SidebarMetadataBlock?,
        key: String,
        markdown: String,
        priority: Int
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.markdown != markdown || current.priority != priority
    }

    nonisolated static func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    nonisolated static func shouldReplaceGitBranch(
        current: SidebarGitBranchState?,
        branch: String,
        isDirty: Bool
    ) -> Bool {
        guard let current else { return true }
        return current.branch != branch || current.isDirty != isDirty
    }

    nonisolated static func shouldReplacePullRequest(
        current: SidebarPullRequestState?,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?
    ) -> Bool {
        guard let current else { return true }
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch: String? = {
            if let normalizedBranch, !normalizedBranch.isEmpty {
                return normalizedBranch
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.branch
        }()
        return current.number != number
            || current.label != label
            || current.url != url
            || current.status != status
            || current.branch != effectiveBranch
            || current.isStale
    }

    nonisolated static func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }
}
