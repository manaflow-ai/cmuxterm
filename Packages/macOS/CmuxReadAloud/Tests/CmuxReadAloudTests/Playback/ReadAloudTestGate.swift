import Foundation

/// A one-use suspension point that deliberately ignores cancellation until released.
actor ReadAloudTestGate<Value: Sendable> {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release(_ value: Value) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}
