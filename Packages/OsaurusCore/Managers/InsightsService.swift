//
//  InsightsService.swift
//  osaurus
//
//  In-memory request/response logging service for debugging and analytics.
//  Uses a ring buffer to limit memory usage.
//

import Combine
import Foundation

@MainActor
final class InsightsService: ObservableObject {
    static let shared = InsightsService()

    // MARK: - Configuration

    /// Maximum number of logs to retain in memory
    private let maxLogCount: Int = 500

    /// Debounce window applied to the search field. Long enough to skip a
    /// typed character while the user is still typing, short enough to feel
    /// instantaneous when they pause.
    private static let searchDebounceMs: Int = 150

    /// Coalescing window for raw-log -> stats / filtered-list updates. Keeps
    /// the UI from doing N filter passes when a burst of requests arrives.
    private static let recomputeDebounceMs: Int = 50

    // MARK: - Published State

    /// All logged requests (most recent first)
    @Published private(set) var logs: [RequestLog] = []

    /// Total request count (may exceed logs.count due to ring buffer)
    @Published private(set) var totalRequestCount: Int = 0

    /// Active filter for path/model search
    @Published var searchFilter: String = ""

    /// Active filter for source
    @Published var sourceFilter: SourceFilter = .all

    /// Active filter for HTTP method
    @Published var methodFilter: MethodFilter = .all

    /// Cached, view-ready filtered list. Recomputed off the UI hot path via
    /// the Combine pipeline in `init()`. SwiftUI views should read this
    /// instead of the legacy computed `filteredLogs`.
    @Published private(set) var displayedLogs: [RequestLog] = []

    /// Cached summary stats. Updated alongside `displayedLogs` so a single
    /// objectWillChange propagates both to the view.
    @Published private(set) var displayedStats: InsightsStats = InsightsStats(
        totalRequests: 0,
        successRate: 0,
        errorCount: 0,
        averageDurationMs: 0,
        inferenceCount: 0,
        totalInputTokens: 0,
        totalOutputTokens: 0,
        averageSpeed: 0
    )

    // MARK: - Computed Properties (legacy / test-only)

    /// Filtered logs based on current filter settings.
    ///
    /// This computed property runs the filter on every access. Views should
    /// read `displayedLogs` instead — it's kept in sync by a Combine pipeline
    /// that debounces search-field typing and coalesces log-append bursts so
    /// every keystroke / token-stream chunk doesn't trigger an O(n) filter
    /// pass on the main actor.
    var filteredLogs: [RequestLog] {
        InsightsService.applyFilters(
            to: logs,
            searchFilter: searchFilter,
            sourceFilter: sourceFilter,
            methodFilter: methodFilter
        )
    }

    /// Summary statistics. Same caveat as `filteredLogs`: views should read
    /// `displayedStats`.
    var stats: InsightsStats {
        InsightsService.computeStats(for: logs)
    }

    // MARK: - Initialization

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // The view bottleneck before this pipeline was that every keystroke
        // in the search field triggered both `filteredLogs` and `stats` to
        // run on the main actor with N=500 logs in the worst case. We now
        // coalesce on log-append bursts (recomputeDebounceMs) and on search
        // typing (searchDebounceMs), and emit a single new value through
        // displayedLogs / displayedStats that the view observes directly.
        let logsPublisher = $logs
            .removeDuplicates { $0.count == $1.count && $0.first?.id == $1.first?.id }
            .debounce(
                for: .milliseconds(Self.recomputeDebounceMs), scheduler: DispatchQueue.main)

        let searchPublisher = $searchFilter
            .removeDuplicates()
            .debounce(for: .milliseconds(Self.searchDebounceMs), scheduler: DispatchQueue.main)

        let sourcePublisher = $sourceFilter.removeDuplicates()
        let methodPublisher = $methodFilter.removeDuplicates()

        Publishers.CombineLatest4(logsPublisher, searchPublisher, sourcePublisher, methodPublisher)
            .map { logs, search, source, method in
                (
                    Self.applyFilters(
                        to: logs, searchFilter: search,
                        sourceFilter: source, methodFilter: method),
                    Self.computeStats(for: logs)
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filtered, stats in
                self?.displayedLogs = filtered
                self?.displayedStats = stats
            }
            .store(in: &cancellables)
    }

    // MARK: - Filter / Stats Implementations

    /// Pure-function filter applied to a snapshot of logs. Lives as a static
    /// helper so the computed `filteredLogs` and the Combine pipeline that
    /// drives `displayedLogs` share the same logic.
    nonisolated static func applyFilters(
        to logs: [RequestLog],
        searchFilter: String,
        sourceFilter: SourceFilter,
        methodFilter: MethodFilter
    ) -> [RequestLog] {
        logs.filter { log in
            if !searchFilter.isEmpty {
                let matchesPath = SearchService.matches(query: searchFilter, in: log.path)
                let matchesModel = log.model.map { SearchService.matches(query: searchFilter, in: $0) } ?? false
                let matchesShortModel = SearchService.matches(query: searchFilter, in: log.shortModelName)
                let matchesPlugin = log.pluginId.map { SearchService.matches(query: searchFilter, in: $0) } ?? false
                if !matchesPath && !matchesModel && !matchesShortModel && !matchesPlugin {
                    return false
                }
            }

            switch sourceFilter {
            case .all:
                break
            case .chatUI:
                if log.source != .chatUI { return false }
            case .httpAPI:
                if log.source != .httpAPI { return false }
            case .plugin:
                if log.source != .plugin { return false }
            }

            switch methodFilter {
            case .all:
                break
            case .get:
                if log.method != "GET" { return false }
            case .post:
                if log.method != "POST" { return false }
            }

            return true
        }
    }

    /// Pure-function stats over a snapshot of logs. Reused by the computed
    /// `stats` and the Combine pipeline that drives `displayedStats`.
    nonisolated static func computeStats(for logs: [RequestLog]) -> InsightsStats {
        let total = logs.count
        let successCount = logs.filter { $0.isSuccess }.count
        let successRate = total > 0 ? Double(successCount) / Double(total) * 100 : 0
        let errors = logs.filter { $0.isError }.count
        let avgDuration = logs.isEmpty ? 0 : logs.map(\.durationMs).reduce(0, +) / Double(logs.count)

        let inferenceLogs = logs.filter { $0.isInference }
        let totalInputTokens = inferenceLogs.reduce(0) { $0 + ($1.inputTokens ?? 0) }
        let totalOutputTokens = inferenceLogs.reduce(0) { $0 + ($1.outputTokens ?? 0) }
        let avgSpeed: Double = {
            let speeds = inferenceLogs.compactMap { $0.tokensPerSecond }
            return speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        }()

        return InsightsStats(
            totalRequests: total,
            successRate: successRate,
            errorCount: errors,
            averageDurationMs: avgDuration,
            inferenceCount: inferenceLogs.count,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            averageSpeed: avgSpeed
        )
    }

    // MARK: - Logging Methods

    /// Log a completed request
    func log(_ request: RequestLog) {
        // Insert at beginning (most recent first)
        logs.insert(request, at: 0)
        totalRequestCount += 1

        // Enforce ring buffer limit
        if logs.count > maxLogCount {
            logs.removeLast(logs.count - maxLogCount)
        }
    }

    /// Clear all logs
    func clear() {
        logs.removeAll()
        totalRequestCount = 0
    }

    /// Clear filters
    func clearFilters() {
        searchFilter = ""
        sourceFilter = .all
        methodFilter = .all
    }
}

// MARK: - Supporting Types

enum SourceFilter: String, CaseIterable {
    case all = "All"
    case chatUI = "Chat"
    case httpAPI = "HTTP"
    case plugin = "Plugin"

    var displayName: String {
        switch self {
        case .all: return L("All")
        case .chatUI: return L("Chat")
        case .httpAPI: return "HTTP"
        case .plugin: return L("Plugin")
        }
    }
}

enum MethodFilter: String, CaseIterable {
    case all = "All"
    case get = "GET"
    case post = "POST"

    var displayName: String {
        switch self {
        case .all: return L("All")
        case .get: return "GET"
        case .post: return "POST"
        }
    }
}

struct InsightsStats {
    let totalRequests: Int
    let successRate: Double
    let errorCount: Int
    let averageDurationMs: Double

    // Inference-specific stats
    let inferenceCount: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let averageSpeed: Double

    var formattedSuccessRate: String {
        String(format: "%.0f%%", successRate)
    }

    var formattedAvgSpeed: String {
        if averageSpeed > 0 {
            return String(format: "%.1f tok/s", averageSpeed)
        }
        return "-"
    }

    var formattedAvgDuration: String {
        if averageDurationMs < 1000 {
            return String(format: "%.0fms", averageDurationMs)
        } else {
            return String(format: "%.1fs", averageDurationMs / 1000)
        }
    }
}

// MARK: - Nonisolated Logging Interface

extension InsightsService {
    /// Maximum stored body size (4 KB) to cap ring buffer memory usage.
    private nonisolated static let maxBodySize = 4096

    private nonisolated static func truncateBody(_ body: String?) -> String? {
        guard let body, body.count > maxBodySize else { return body }
        return String(body.prefix(maxBodySize)) + "…[truncated]"
    }

    /// Thread-safe logging from non-main-actor contexts
    nonisolated static func logRequest(
        source: RequestSource,
        method: String,
        path: String,
        statusCode: Int,
        durationMs: Double,
        requestBody: String? = nil,
        responseBody: String? = nil,
        userAgent: String? = nil,
        pluginId: String? = nil,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: RequestLog.FinishReason? = nil,
        errorMessage: String? = nil
    ) {
        let trimmedRequest = truncateBody(requestBody)
        let trimmedResponse = truncateBody(responseBody)

        Task { @MainActor in
            let log = RequestLog(
                source: source,
                method: method,
                path: path,
                statusCode: statusCode,
                durationMs: durationMs,
                requestBody: trimmedRequest,
                responseBody: trimmedResponse,
                userAgent: userAgent,
                pluginId: pluginId,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                temperature: temperature,
                maxTokens: maxTokens,
                toolCalls: toolCalls,
                finishReason: finishReason,
                errorMessage: errorMessage
            )
            shared.log(log)
        }
    }

    /// Legacy compatibility for ChatEngine inference logging
    nonisolated static func logInference(
        source: RequestSource,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        durationMs: Double,
        temperature: Float?,
        maxTokens: Int,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: RequestLog.FinishReason = .stop,
        errorMessage: String? = nil
    ) {
        logRequest(
            source: source,
            method: "POST",
            path: "/chat/completions",
            statusCode: errorMessage != nil ? 500 : 200,
            durationMs: durationMs,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            temperature: temperature,
            maxTokens: maxTokens,
            toolCalls: toolCalls,
            finishReason: finishReason,
            errorMessage: errorMessage
        )
    }

    /// Logs HTTP requests with optional inference data
    nonisolated static func logAsync(
        method: String,
        path: String,
        clientIP: String = "127.0.0.1",
        userAgent: String? = nil,
        requestBody: String? = nil,
        responseBody: String? = nil,
        responseStatus: Int,
        durationMs: Double,
        model: String? = nil,
        tokensInput: Int? = nil,
        tokensOutput: Int? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: RequestLog.FinishReason? = nil,
        errorMessage: String? = nil
    ) {
        let source: RequestSource = method == "CHAT" ? .chatUI : .httpAPI

        logRequest(
            source: source,
            method: method == "CHAT" ? "POST" : method,
            path: path,
            statusCode: responseStatus,
            durationMs: durationMs,
            requestBody: requestBody,
            responseBody: responseBody,
            userAgent: userAgent,
            model: model,
            inputTokens: tokensInput,
            outputTokens: tokensOutput,
            temperature: temperature,
            maxTokens: maxTokens,
            toolCalls: toolCalls,
            finishReason: finishReason,
            errorMessage: errorMessage
        )
    }
}
