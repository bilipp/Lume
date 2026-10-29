import Foundation
import LumeCloudKit

/// Keeps the Lume Cloud socket open while running: hands every `seq` to
/// `onSeq`, reconnects with exponential backoff after a drop, and asks `probe`
/// for the precise error when the upgrade is refused (401 / 404).
///
/// The socket is only a hint, so nothing here retries a pull or surfaces a
/// transient failure: correctness rests on the launch and foreground pulls.
@MainActor
final class LumeCloudEventListener {
    nonisolated struct Backoff: Equatable {
        var initial: Duration
        var maximum: Duration

        static let standard = Backoff(initial: .seconds(1), maximum: .seconds(60))

        /// The wait before reconnecting after `failures` consecutive drops (≥ 1).
        func delay(afterFailures failures: Int) -> Duration {
            let exponent = min(max(failures - 1, 0), 30)
            let scaled = initial * (1 << exponent)
            return min(scaled, maximum)
        }
    }

    /// What to do after a refused upgrade, once `probe` has run.
    enum ProbeVerdict {
        case reconnect
        case stop
    }

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let connect: () -> AsyncThrowingStream<Int, Error>
    private let onSeq: (Int) async -> Void
    private let probe: () async -> ProbeVerdict
    private let backoff: Backoff
    private let sleep: Sleep
    private var task: Task<Void, Never>?

    /// `probe` runs after the socket fails with `.badAuth` or `.notFound`.
    init(
        backoff: Backoff = .standard,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        connect: @escaping () -> AsyncThrowingStream<Int, Error>,
        onSeq: @escaping (Int) async -> Void,
        probe: @escaping () async -> ProbeVerdict
    ) {
        self.backoff = backoff
        self.sleep = sleep
        self.connect = connect
        self.onSeq = onSeq
        self.probe = probe
    }

    var isRunning: Bool {
        task != nil
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                for try await seq in connect() {
                    failures = 0
                    await onSeq(seq)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if Self.isRefusedUpgrade(error), await probe() == .stop {
                    if !Task.isCancelled {
                        task = nil
                    }
                    return
                }
            }
            guard !Task.isCancelled else { return }
            failures += 1
            do {
                try await sleep(backoff.delay(afterFailures: failures))
            } catch {
                return
            }
        }
    }

    private static func isRefusedUpgrade(_ error: any Error) -> Bool {
        switch error as? LumeCloudError {
        case .badAuth, .notFound: true
        default: false
        }
    }
}
