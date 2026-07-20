import XCTest
@testable import CCTransCore

final class AsyncTimeoutTests: XCTestCase {
    func testReturnsValueWhenOperationFinishesFirst() async {
        let value = await withAsyncTimeout(seconds: 5, fallback: -1) { 42 }
        XCTAssertEqual(value, 42)
    }

    /// The point of the helper: a non-cancellable, slow operation must NOT hold the caller
    /// past the deadline. `Thread.sleep` ignores task cancellation, mimicking a hung system
    /// API (e.g. AppTransaction.shared). If withAsyncTimeout awaited the orphan, this test
    /// would take ~3s instead of ~0.1s.
    func testReturnsFallbackWithoutAwaitingHungOperation() async {
        let start = Date()
        let value = await withAsyncTimeout(seconds: 0.1, fallback: -1) {
            blockingSleep(3)  // ignores Task.cancel — simulates a hang
            return 99
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(value, -1)
        XCTAssertLessThan(elapsed, 2.0, "helper waited for the orphaned operation")
    }
}

/// Synchronous blocking wait — mimics a system API that ignores task cancellation.
/// Isolated to a non-async function so the compiler allows the blocking `Thread.sleep`.
private func blockingSleep(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}
