import Foundation

/// Run `operation`, but stop waiting after `seconds` and return `fallback` instead.
///
/// Why not a structured `withThrowingTaskGroup`: a task group awaits ALL of its child
/// tasks when the scope exits, so if the operation ignores cancellation (some system
/// async APIs do) the group re-blocks waiting for it — defeating the timeout. This races
/// the work against a sleep using UNSTRUCTURED tasks and abandons the loser, so a hung,
/// non-cancellable operation can never hold the caller past `seconds`.
///
/// Concretely this guards StoreKit's `AppTransaction.shared`, which has no built-in
/// timeout and can block indefinitely on an implicit App Store network fetch.
///
/// - Parameter onTimeout: invoked once if the deadline wins the race (diagnostics only).
public func withAsyncTimeout<T: Sendable>(
    seconds: Double,
    fallback: T,
    onTimeout: (@Sendable () -> Void)? = nil,
    operation: @escaping @Sendable () async -> T
) async -> T {
    let once = TimeoutOnce()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        // Work task: resume with the real value if it finishes first.
        Task {
            let value = await operation()
            if once.claim() {
                continuation.resume(returning: value)
            }
        }
        // Deadline task: resume with the fallback if the sleep finishes first. The work
        // task is left running (orphaned) — cancel() is best-effort since the operation
        // may ignore it — but it can no longer block us.
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() {
                onTimeout?()
                continuation.resume(returning: fallback)
            }
        }
    }
}

/// One-shot guard so the work/deadline race resumes the continuation EXACTLY once —
/// resuming a `CheckedContinuation` twice is a fatal error.
private final class TimeoutOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
