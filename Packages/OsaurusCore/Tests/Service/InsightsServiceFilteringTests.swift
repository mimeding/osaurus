//
//  InsightsServiceFilteringTests.swift
//  osaurusTests
//
//  Unit tests for the pure-function filter and stats helpers that drive the
//  Insights view. Keeping these as static helpers means we can verify their
//  behavior without spinning up the MainActor singleton or the debounced
//  Combine pipeline. The pipeline itself feeds these helpers from
//  `(logs, search, source, method)`; if the helpers are correct, the
//  pipeline's job is just to call them on the right cadence.
//

import Foundation
import Testing

@testable import OsaurusCore

private func makeLog(
    source: RequestSource = .httpAPI,
    method: String = "POST",
    path: String = "/v1/chat/completions",
    statusCode: Int = 200,
    durationMs: Double = 100,
    model: String? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    finishReason: RequestLog.FinishReason? = nil,
    errorMessage: String? = nil,
    pluginId: String? = nil
) -> RequestLog {
    RequestLog(
        source: source,
        method: method,
        path: path,
        statusCode: statusCode,
        durationMs: durationMs,
        pluginId: pluginId,
        model: model,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        finishReason: finishReason,
        errorMessage: errorMessage
    )
}

struct InsightsServiceFilteringTests {

    @Test func emptyFiltersReturnAllLogs() {
        let logs = [makeLog(), makeLog(method: "GET", path: "/health", statusCode: 200)]
        let result = InsightsService.applyFilters(
            to: logs, searchFilter: "", sourceFilter: .all, methodFilter: .all)
        #expect(result.count == logs.count)
    }

    @Test func sourceFilterIsolatesEntries() {
        let chat = makeLog(source: .chatUI)
        let http = makeLog(source: .httpAPI)
        let plugin = makeLog(source: .plugin)
        let logs = [chat, http, plugin]

        let httpOnly = InsightsService.applyFilters(
            to: logs, searchFilter: "", sourceFilter: .httpAPI, methodFilter: .all)
        #expect(httpOnly.count == 1)
        #expect(httpOnly[0].source == .httpAPI)
    }

    @Test func methodFilterIsolatesEntries() {
        let post = makeLog(method: "POST")
        let get = makeLog(method: "GET")
        let result = InsightsService.applyFilters(
            to: [post, get], searchFilter: "", sourceFilter: .all, methodFilter: .get)
        #expect(result.count == 1)
        #expect(result[0].method == "GET")
    }

    @Test func computeStatsHandlesEmptyInput() {
        let stats = InsightsService.computeStats(for: [])
        #expect(stats.totalRequests == 0)
        #expect(stats.successRate == 0)
        #expect(stats.errorCount == 0)
        #expect(stats.averageDurationMs == 0)
        #expect(stats.inferenceCount == 0)
    }

    @Test func computeStatsCountsSuccessAndErrors() {
        let ok1 = makeLog(statusCode: 200)
        let ok2 = makeLog(statusCode: 204)
        let err = makeLog(statusCode: 500, errorMessage: "boom")
        let stats = InsightsService.computeStats(for: [ok1, ok2, err])
        #expect(stats.totalRequests == 3)
        // Two successes out of three => ~66.67%
        #expect(abs(stats.successRate - 200.0 / 3.0) < 0.001)
        #expect(stats.errorCount == 1)
    }

    @Test func computeStatsAveragesDuration() {
        let a = makeLog(durationMs: 100)
        let b = makeLog(durationMs: 300)
        let c = makeLog(durationMs: 500)
        let stats = InsightsService.computeStats(for: [a, b, c])
        #expect(abs(stats.averageDurationMs - 300) < 0.001)
    }

    @Test func computeStatsTracksInferenceTokens() {
        // path "/chat..." is what marks a log as inference. Use the standard
        // chat-completions path so it matches `isInference`.
        let inf1 = makeLog(
            path: "/v1/chat/completions",
            inputTokens: 10, outputTokens: 20, finishReason: .stop)
        let inf2 = makeLog(
            path: "/v1/chat/completions",
            inputTokens: 5, outputTokens: 15, finishReason: .stop)
        // A non-inference log shouldn't contribute.
        let other = makeLog(path: "/v1/models", inputTokens: 100, outputTokens: 200)
        let stats = InsightsService.computeStats(for: [inf1, inf2, other])
        #expect(stats.inferenceCount == 2)
        #expect(stats.totalInputTokens == 15)
        #expect(stats.totalOutputTokens == 35)
    }
}
