import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct RemoteGenerationMetricsTests {
    @Test
    func generationMetricsCanEstimateMissingStreamingRates() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let firstDeltaAt = startedAt.addingTimeInterval(2)
        let finishedAt = firstDeltaAt.addingTimeInterval(4)
        let stats = [
            RemoteGenerationStats(
                usage: RemoteGenerationUsage(
                    promptTokens: 100,
                    completionTokens: 40,
                    totalTokens: 140,
                    promptTokensPerSecond: nil,
                    completionTokensPerSecond: nil
                ),
                requestStartedAt: startedAt,
                firstDeltaAt: firstDeltaAt,
                finishedAt: finishedAt,
                generatedCharacterCount: 120
            )
        ]

        let metrics = RemoteGenerationClient.generationMetrics(
            stats,
            estimateMissingRates: true
        )

        #expect(metrics?.promptTokensPerSecond == 50)
        #expect(metrics?.completionTokensPerSecond == 10)
        #expect(metrics?.responseDurationSeconds == 6)
    }

    @Test
    func generationMetricsKeepsMissingRatesEmptyUnlessEstimationIsEnabled() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let firstDeltaAt = startedAt.addingTimeInterval(2)
        let finishedAt = firstDeltaAt.addingTimeInterval(4)
        let stats = [
            RemoteGenerationStats(
                usage: RemoteGenerationUsage(
                    promptTokens: 100,
                    completionTokens: 40,
                    totalTokens: 140,
                    promptTokensPerSecond: nil,
                    completionTokensPerSecond: nil
                ),
                requestStartedAt: startedAt,
                firstDeltaAt: firstDeltaAt,
                finishedAt: finishedAt,
                generatedCharacterCount: 120
            )
        ]

        let metrics = RemoteGenerationClient.generationMetrics(stats)

        #expect(metrics?.promptTokensPerSecond == nil)
        #expect(metrics?.completionTokensPerSecond == nil)
        #expect(metrics?.responseDurationSeconds == 6)
    }

}
