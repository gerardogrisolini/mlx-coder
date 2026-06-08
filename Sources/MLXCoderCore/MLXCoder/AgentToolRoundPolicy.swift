//
//  AgentToolRoundPolicy.swift
//  mlx-coder
//

public enum AgentToolRoundPolicy {
    public static let minimumMaxToolRounds = 1
    public static let defaultMaxToolRounds = 1000

    public static func isValidMaxToolRounds(_ value: Int) -> Bool {
        value >= minimumMaxToolRounds
    }

    public static func normalizedMaxToolRounds(_ value: Int) -> Int {
        max(minimumMaxToolRounds, value)
    }
}

