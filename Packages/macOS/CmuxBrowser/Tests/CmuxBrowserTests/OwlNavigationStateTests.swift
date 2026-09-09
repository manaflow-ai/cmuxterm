import Foundation
import Testing
@testable import CmuxBrowser

@Suite("OWL native navigation state")
struct OwlNavigationStateTests {
    @Test("Foundation JSON numbers stay numeric while booleans stay boolean")
    func cdpJSONNumberDiscrimination() throws {
        let zero = try JSONSerialization.jsonObject(with: Data("0".utf8))
        let one = try JSONSerialization.jsonObject(with: Data("1".utf8))
        let boolean = try JSONSerialization.jsonObject(with: Data("true".utf8))

        #expect(CDPValue(any: zero) == .number(0))
        #expect(CDPValue(any: one) == .number(1))
        #expect(CDPValue(any: boolean) == .bool(true))
    }

    @Test("OWL mouse kinds match the fork's Mojo enum")
    func mouseKindMapping() {
        #expect(OwlFreshMouseKind(cdpType: "mousePressed") == .down)
        #expect(OwlFreshMouseKind(cdpType: "mouseReleased") == .up)
        #expect(OwlFreshMouseKind(cdpType: "mouseMoved") == .move)
        #expect(OwlFreshMouseKind(cdpType: "mouseWheel") == .wheel)
    }

    @Test("OWL history reports no-op traversal at either edge")
    func historyNoOps() {
        let first = URL(string: "https://one.example")!
        let second = URL(string: "https://two.example")!
        var history = OwlNavigationHistoryState(initialURL: first)

        #expect(history.targetURL(offset: -1) == nil)
        #expect(history.targetURL(offset: 1) == nil)
        history.commitDestination(second)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.targetURL(offset: -1) == first)
        #expect(history.targetURL(offset: 1) == nil)
        history.commitTraversal(to: first)
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
    }

    @Test("OWL traversal preserves the cursor when URLs repeat")
    func traversalPreservesDuplicateURLCursor() {
        let first = URL(string: "https://one.example")!
        let second = URL(string: "https://two.example")!
        var history = OwlNavigationHistoryState(initialURL: first)
        history.commitDestination(second)
        history.commitDestination(first)

        history.commitTraversal(to: second, offset: -1)
        #expect(history.canGoBack)
        #expect(history.canGoForward)
        history.commitTraversal(to: first, offset: 1)
        #expect(!history.canGoForward)
    }

    @Test("OWL traversal treats an HTTP origin slash as equivalent")
    func traversalNormalizesHTTPOriginSlash() {
        let origin = URL(string: "https://one.example")!
        let second = URL(string: "https://two.example/path")!
        var history = OwlNavigationHistoryState(initialURL: origin)
        history.commitDestination(second)

        history.commitTraversal(
            to: URL(string: "https://one.example/")!,
            offset: -1
        )
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
    }

    @Test("OWL traversal mismatch does not rewrite history")
    func traversalMismatchDoesNotRewriteHistory() {
        let first = URL(string: "https://one.example")!
        let second = URL(string: "https://two.example")!
        var history = OwlNavigationHistoryState(initialURL: first)
        history.commitDestination(second)
        history.commitTraversal(to: URL(string: "https://other.example")!, offset: -1)
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
    }

    @Test("OWL title-only events cannot complete a navigation")
    func titleOnlyEventsDoNotComplete() {
        #expect(!OwlNavigationCompletionPredicate.accepts(
            loading: false,
            sawLoadingEvent: false,
            targetMatches: true
        ))
        #expect(!OwlNavigationCompletionPredicate.accepts(
            loading: false,
            sawLoadingEvent: true,
            targetMatches: false
        ))
        #expect(!OwlNavigationCompletionPredicate.accepts(
            loading: true,
            sawLoadingEvent: true,
            targetMatches: true
        ))
        #expect(OwlNavigationCompletionPredicate.accepts(
            loading: false,
            sawLoadingEvent: true,
            targetMatches: true
        ))
    }

    @Test("OWL readiness requires a fresh complete document")
    func readinessRequiresFreshDocument() {
        #expect(!OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: false,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: false,
            navigationType: "navigate"
        ))
        #expect(!OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: false,
            requiresReloadNavigation: false,
            navigationType: "navigate"
        ))
        #expect(!OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: false,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: false,
            navigationType: "navigate"
        ))
        #expect(!OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: true,
            navigationType: "back_forward"
        ))
        #expect(OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: false,
            navigationType: "navigate"
        ))
        #expect(OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: true,
            targetMatches: true,
            readyState: "complete",
            documentEpochAdvanced: true,
            requiresReloadNavigation: true,
            navigationType: "reload"
        ))
    }
}
