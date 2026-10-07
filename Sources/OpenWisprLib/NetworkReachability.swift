import Foundation
import Network

/// Whether the device has a usable network path. Injectable so the rewrite flow
/// can be tested without touching the network stack.
protocol NetworkReachability {
    /// Waits up to `timeout` for the first path report if none has arrived yet
    /// (a monitor started a moment ago has nothing to say), then answers. Still
    /// unknown after that counts as online.
    func isOnline(waitingUpTo timeout: TimeInterval) async -> Bool
}

enum ReachabilityWait {
    /// How long the first eligible dictation after launch waits for the monitor.
    static let firstUpdateTimeout: TimeInterval = 0.3
    static let pollInterval: TimeInterval = 0.02

    /// Polls `status` until it is known or `timeout` has passed. The clock is
    /// counted in poll steps, so a fake `sleep` makes this deterministic.
    static func resolve(
        status: () -> NWPath.Status?,
        timeout: TimeInterval,
        pollInterval: TimeInterval = ReachabilityWait.pollInterval,
        sleep: (TimeInterval) async -> Void
    ) async -> Bool {
        var waited: TimeInterval = 0
        while status() == nil && waited < timeout {
            await sleep(pollInterval)
            waited += pollInterval
        }
        return PathMonitorReachability.isOnline(status: status())
    }
}

/// `NWPathMonitor`-backed reachability. It observes the system's network path
/// only and sends no traffic.
final class PathMonitorReachability: NetworkReachability {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "\(ProductInfo.bundleIdentifier).reachability")
    private let lock = NSLock()
    private var status: NWPath.Status?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            self.status = path.status
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    private var currentStatus: NWPath.Status? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    func isOnline(waitingUpTo timeout: TimeInterval) async -> Bool {
        await ReachabilityWait.resolve(
            status: { currentStatus },
            timeout: timeout,
            sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        )
    }

    /// Only a definite `.unsatisfied` means offline. `.requiresConnection` (for
    /// example a VPN that connects on demand) is worth trying, and an unknown
    /// status is not evidence of being offline: the request's own failure
    /// handling covers a wrong guess, whereas guessing offline would silently
    /// skip a rewrite.
    static func isOnline(status: NWPath.Status?) -> Bool {
        status != .unsatisfied
    }
}
