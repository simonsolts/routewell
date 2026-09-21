import Foundation
import Testing
@testable import RoutewellKit

@Suite struct MutationGateTests {
    @Test func acquireWhenFreeSucceedsImmediately() async throws {
        let gate = MutationGate()
        #expect(await gate.isHeld == false)
        let token = try await gate.acquire()
        #expect(await gate.isHeld == true)
        await gate.release(token)
        #expect(await gate.isHeld == false)
    }

    @Test func secondAcquireWaitsUntilReleased() async throws {
        let gate = MutationGate()
        let firstToken = try await gate.acquire()

        let order = OrderRecorder()
        let waiter = Task {
            let token = try await gate.acquire()
            await order.record("acquired")
            return token
        }

        // Give the waiter a chance to actually start waiting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await order.events().isEmpty)

        await order.record("releasing")
        await gate.release(firstToken)

        let secondToken = try await waiter.value
        let events = await order.events()
        #expect(events == ["releasing", "acquired"])
        await gate.release(secondToken)
    }

    @Test func cancelledWaiterNeverAcquiresAndDoesNotBlockNextWaiter() async throws {
        let gate = MutationGate()
        let firstToken = try await gate.acquire()

        let cancelledWaiter = Task {
            try await gate.acquire()
        }
        try await Task.sleep(for: .milliseconds(20))
        cancelledWaiter.cancel()

        let thirdWaiter = Task {
            try await gate.acquire()
        }
        try await Task.sleep(for: .milliseconds(20))
        await gate.release(firstToken)

        let thirdToken = try await thirdWaiter.value
        await gate.release(thirdToken)

        let cancelledResult = await cancelledWaiter.result
        #expect(throws: (any Error).self) {
            try cancelledResult.get()
        }
    }

    @Test func releasingForeignOrStaleTokenIsANoOp() async throws {
        let gate = MutationGate()
        let token = try await gate.acquire()

        struct TokenPeeker {
            static func makeUnrelatedToken() async -> MutationGateToken {
                let other = MutationGate()
                let t = try! await other.acquire()
                await other.release(t)
                return t
            }
        }
        let foreignToken = await TokenPeeker.makeUnrelatedToken()

        await gate.release(foreignToken)
        #expect(await gate.isHeld == true)

        await gate.release(token)
        #expect(await gate.isHeld == false)

        // Releasing the now-stale token again is a no-op.
        await gate.release(token)
        #expect(await gate.isHeld == false)
    }

    @Test func waitersAreServedInOrder() async throws {
        let gate = MutationGate()
        let firstToken = try await gate.acquire()

        let order = OrderRecorder()
        let second = Task {
            let token = try await gate.acquire()
            await order.record("second")
            return token
        }
        try await Task.sleep(for: .milliseconds(20))
        let third = Task {
            let token = try await gate.acquire()
            await order.record("third")
            return token
        }
        try await Task.sleep(for: .milliseconds(20))

        await gate.release(firstToken)
        let secondToken = try await second.value
        await gate.release(secondToken)
        let thirdToken = try await third.value
        await gate.release(thirdToken)

        let events = await order.events()
        #expect(events == ["second", "third"])
    }
}

private actor OrderRecorder {
    private var recordedEvents: [String] = []
    func record(_ event: String) { recordedEvents.append(event) }
    func events() -> [String] { recordedEvents }
}
