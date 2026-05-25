//
//  MLXServerGenerationGate.swift
//  mlx-server
//

actor MLXServerGenerationGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
