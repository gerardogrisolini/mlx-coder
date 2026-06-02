//
//  MLXServerGenerationGate.swift
//  mlx-server
//

import Foundation

actor MLXServerGenerationGate {
    private var activeLeaseID: UUID?
    private var waiters: [Waiter] = []

    func acquire() async throws -> MLXServerGenerationLease {
        let leaseID = UUID()
        if activeLeaseID == nil {
            activeLeaseID = leaseID
            return MLXServerGenerationLease(id: leaseID, gate: self)
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: leaseID, continuation: continuation))
            }
        }, onCancel: {
            Task {
                await self.cancelWaiter(id: leaseID)
            }
        })
    }

    fileprivate func release(id: UUID) {
        guard activeLeaseID == id else {
            return
        }
        guard !waiters.isEmpty else {
            activeLeaseID = nil
            return
        }

        let next = waiters.removeFirst()
        activeLeaseID = next.id
        next.continuation.resume(returning: MLXServerGenerationLease(id: next.id, gate: self))
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<MLXServerGenerationLease, any Error>
    }
}

struct MLXServerGenerationLease: Sendable {
    fileprivate let id: UUID
    fileprivate let gate: MLXServerGenerationGate

    func release() async {
        await gate.release(id: id)
    }
}
