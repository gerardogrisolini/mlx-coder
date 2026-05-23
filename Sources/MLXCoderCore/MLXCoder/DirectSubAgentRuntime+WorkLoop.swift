//
//  Split from DirectSubAgentRuntime.swift
//  MLXCoder
//

import Foundation

extension DirectSubAgentRuntime {
    public func queuePrompt(_ prompt: String, for agentID: String) throws {
        guard var agent = agents[agentID] else {
            throw DirectSubAgentRuntimeError.agentNotFound(agentID)
        }
        guard agent.status != .closed else {
            throw DirectSubAgentRuntimeError.agentClosed(agent.name)
        }

        agent.pendingPrompts.append(prompt)
        agent.latestError = nil
        if agent.status != .running {
            agent.status = .queued
        }
        agents[agentID] = agent
        startAgentIfNeeded(agentID: agentID)
    }

    public func startAgentIfNeeded(agentID: String) {
        guard var agent = agents[agentID],
              agent.runTask == nil else {
            return
        }

        agent.runTask = Task {
            await self.runAgentLoop(agentID: agentID)
        }
        agents[agentID] = agent
    }

    public func runAgentLoop(agentID: String) async {
        while true {
            guard let work = nextWork(for: agentID) else {
                return
            }

            do {
                let response = try await work.backend.sendPrompt(
                    sessionID: work.sessionID,
                    prompt: work.prompt,
                    attachments: [],
                    onEvent: { _ in }
                )
                recordCompletion(response, agentID: agentID)
            } catch is CancellationError {
                recordCancellation(agentID: agentID)
                return
            } catch {
                recordFailure(error, agentID: agentID)
                return
            }
        }
    }

    public func nextWork(for agentID: String) -> AgentWork? {
        guard var agent = agents[agentID] else {
            return nil
        }
        guard agent.status != .closed else {
            agent.runTask = nil
            agents[agentID] = agent
            return nil
        }
        guard !agent.pendingPrompts.isEmpty else {
            agent.runTask = nil
            if agent.status != .failed {
                agent.status = .idle
            }
            agents[agentID] = agent
            return nil
        }

        let prompt = agent.pendingPrompts.removeFirst()
        agent.status = .running
        agents[agentID] = agent

        return AgentWork(
            backend: agent.backend,
            sessionID: agent.sessionID,
            prompt: prompt
        )
    }

    public func recordCompletion(
        _ response: DirectAgentResponse,
        agentID: String
    ) {
        guard var agent = agents[agentID] else {
            return
        }
        agent.latestOutput = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.latestError = nil
        agent.status = agent.pendingPrompts.isEmpty ? .idle : .queued
        agents[agentID] = agent
    }

    public func recordFailure(
        _ error: Error,
        agentID: String
    ) {
        guard var agent = agents[agentID] else {
            return
        }
        agent.pendingPrompts.removeAll()
        agent.runTask = nil
        if agent.status != .closed {
            agent.status = .failed
            agent.latestError = error.localizedDescription
        }
        agents[agentID] = agent
    }

    public func recordCancellation(agentID: String) {
        guard var agent = agents[agentID] else {
            return
        }
        agent.pendingPrompts.removeAll()
        agent.runTask = nil
        if agent.status != .closed {
            agent.status = .closed
            agent.latestError = "Cancelled."
        }
        agents[agentID] = agent
    }
}
