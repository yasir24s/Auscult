import Foundation

/// Runs blocking socket work off Swift's cooperative thread pool.
///
/// The lockdown stack is unavoidably synchronous — Secure Transport's IO
/// callbacks are C functions doing blocking `read`/`write`, and there is no
/// async equivalent that can adopt an existing descriptor. Calling that
/// directly from an `async` context parks a cooperative thread inside a
/// syscall. With several transports probing concurrently that exhausts the pool
/// (it is sized to the core count) and the whole process deadlocks — which is
/// exactly what a full run did before this existed.
///
/// So every blocking chain gets dispatched to a real thread and awaited through
/// a continuation. The caller suspends properly instead of blocking.
enum BlockingIO {
    private static let queue = DispatchQueue(
        label: "com.yasir.auscult.blocking-io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        let box = UncheckedBox(body)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try box.value()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Fire-and-forget variant for teardown, where a failure changes nothing.
    static func runIgnoringErrors(_ body: @escaping () -> Void) async {
        _ = try? await run { body() }
    }

    /// The closure captures sockets and TLS contexts, which are reference types
    /// the pool guarantees single-threaded access to. `Sendable` can't express
    /// that, so we assert it.
    private final class UncheckedBox<T>: @unchecked Sendable {
        let value: () throws -> T
        init(_ value: @escaping () throws -> T) { self.value = value }
    }
}
