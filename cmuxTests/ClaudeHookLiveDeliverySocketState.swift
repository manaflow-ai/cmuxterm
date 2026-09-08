import Foundation

extension ClaudeHookLiveDeliveryHarness {
    final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private let notifications = AgentHookTestNotificationPipeline()
        private var commands: [String] = []
        private let listenerFD: Int32
        private let serverStopped = DispatchSemaphore(value: 0)
        private var serverStarted = false
        private var stopped = false
        private var listenerClosed = false

        init(listenerFD: Int32) {
            self.listenerFD = listenerFD
        }

        func markServerStarted() {
            lock.lock()
            serverStarted = true
            let shouldStop = stopped
            lock.unlock()
            if shouldStop {
                shutdownAndCloseListener()
            }
        }

        func serverIsStopped() -> Bool {
            lock.lock()
            let value = stopped
            lock.unlock()
            return value
        }

        func signalServerStopped() {
            serverStopped.signal()
        }

        func stopServer() {
            lock.lock()
            guard !stopped else {
                lock.unlock()
                return
            }
            stopped = true
            let shouldWait = serverStarted
            lock.unlock()

            shutdownAndCloseListener()
            if shouldWait {
                _ = serverStopped.wait(timeout: .now() + 2)
            }
        }

        private func shutdownAndCloseListener() {
            lock.lock()
            guard !listenerClosed else {
                lock.unlock()
                return
            }
            listenerClosed = true
            lock.unlock()
            _ = Darwin.shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
        }

        func append(_ command: String) {
            lock.lock()
            commands.append(contentsOf: [command] + notifications.effects(for: command))
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
        }
    }
}
