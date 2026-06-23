import CoreGraphics
import Foundation

public enum AnalyticsProvider: String, Codable, CaseIterable {
    case codex
    case claudeCode
    case gemini
    case deepseek
    case glm
    case openAIAPI
    case anthropicAPI
    case googleAIAPI
    case deepseekAPI
    case glmAPI

    public var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .claudeCode:
            "Claude Code"
        case .gemini:
            "Gemini"
        case .deepseek:
            "DeepSeek"
        case .glm:
            "GLM"
        case .openAIAPI:
            "OpenAI API"
        case .anthropicAPI:
            "Anthropic API"
        case .googleAIAPI:
            "Gemini API"
        case .deepseekAPI:
            "DeepSeek API"
        case .glmAPI:
            "GLM API"
        }
    }
}

public enum AnalyticsSectionFreshness: Equatable {
    case live
    case local
    case offline
    case unsupported
}

public struct AnalyticsMetricRow: Equatable {
    public let title: String
    public let value: String
    public let subtitle: String?
    public let progressPercent: Int?

    public init(title: String, value: String, subtitle: String? = nil, progressPercent: Int? = nil) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.progressPercent = progressPercent.map(clampDashboardPercent)
    }
}

public struct AnalyticsSection: Equatable {
    public let id: String
    public let provider: AnalyticsProvider
    public let title: String
    public let subtitle: String
    public let freshness: AnalyticsSectionFreshness
    public let rows: [AnalyticsMetricRow]
    public let message: String?

    public init(
        id: String,
        provider: AnalyticsProvider,
        title: String,
        subtitle: String,
        freshness: AnalyticsSectionFreshness,
        rows: [AnalyticsMetricRow],
        message: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.subtitle = subtitle
        self.freshness = freshness
        self.rows = rows
        self.message = message
    }

    public var isDisplayableUsage: Bool {
        switch freshness {
        case .live, .local:
            return !rows.isEmpty
        case .offline, .unsupported:
            return false
        }
    }

    public static func displayableUsageSections(from sections: [AnalyticsSection]) -> [AnalyticsSection] {
        sections.filter(\.isDisplayableUsage)
    }

    public static func shouldShowUsageWindow(for sections: [AnalyticsSection]) -> Bool {
        !sections.isEmpty
    }
}

public enum DashboardWindowLayout {
    public static let preferredWidth: CGFloat = 380
    private static let headerHeight: CGFloat = 52
    private static let footerHeight: CGFloat = 24
    private static let sectionSpacing: CGFloat = 10
    private static let sectionCardBaseHeight: CGFloat = 84
    private static let customSectionCardPadding: CGFloat = 16
    private static let subscriptionHeaderHeight: CGFloat = 42
    private static let subscriptionLimitCardHeight: CGFloat = 104
    private static let subscriptionVerticalSpacing: CGFloat = 12
    private static let apiUsageSectionHeight: CGFloat = 196
    private static let compactSectionRowHeight: CGFloat = 28
    private static let richSectionRowHeight: CGFloat = 58
    private static let sectionRowSpacing: CGFloat = 8
    private static let sectionEmptyRowHeight: CGFloat = 32

    public static func preferredSize(forSectionCount rawSectionCount: Int) -> CGSize {
        let sections: [AnalyticsSection] = (0..<max(1, rawSectionCount)).map { index in
            AnalyticsSection(
                id: "placeholder-\(index)",
                provider: .codex,
                title: "Section",
                subtitle: "placeholder",
                freshness: .offline,
                rows: []
            )
        }

        return preferredSize(forSections: sections)
    }

    public static func preferredSize(forSections sections: [AnalyticsSection]) -> CGSize {
        let visibleSections = sections.isEmpty ? [emptyPlaceholderSection] : sections
        let width: CGFloat = preferredWidth

        let sectionHeights = visibleSections.reduce(CGFloat(0)) { total, section in
            total + sectionHeight(for: section)
        }
        let sectionSpacingHeight = CGFloat(max(0, visibleSections.count - 1)) * sectionSpacing
        let contentHeight = headerHeight + sectionHeights + sectionSpacingHeight + footerHeight

        return CGSize(width: width, height: contentHeight)
    }

    public static func framePreservingTopLeft(from currentFrame: CGRect, preferredSize: CGSize) -> CGRect {
        CGRect(
            origin: CGPoint(x: currentFrame.minX, y: currentFrame.maxY - preferredSize.height),
            size: preferredSize
        )
    }

    private static func sectionHeight(for section: AnalyticsSection) -> CGFloat {
        guard !section.rows.isEmpty else {
            return sectionCardBaseHeight + sectionEmptyRowHeight
        }

        switch AnalyticsSectionPresentation.displayStyle(for: section) {
        case .subscriptionUsage:
            let cardCount = CGFloat(AnalyticsSectionPresentation.subscriptionCards(for: section).count)
            let cardsHeight = (cardCount * subscriptionLimitCardHeight)
                + (max(0, cardCount - 1) * subscriptionVerticalSpacing)
            return customSectionCardPadding
                + subscriptionHeaderHeight
                + subscriptionVerticalSpacing
                + cardsHeight
        case .apiUsage:
            return customSectionCardPadding + apiUsageSectionHeight
        case .metrics:
            break
        }

        let rowCount = CGFloat(section.rows.count)
        let rowHeights = section.rows.reduce(CGFloat(0)) { total, row in
            total + sectionRowHeight(for: row)
        }
        let rowsHeight = rowHeights + (max(0, rowCount - 1) * sectionRowSpacing)

        return sectionCardBaseHeight + rowsHeight
    }

    private static func sectionRowHeight(for row: AnalyticsMetricRow) -> CGFloat {
        row.subtitle == nil && row.progressPercent == nil ? compactSectionRowHeight : richSectionRowHeight
    }

    private static var emptyPlaceholderSection: AnalyticsSection {
        AnalyticsSection(
            id: "placeholder-empty",
            provider: .codex,
            title: "No data",
            subtitle: "No data",
            freshness: .offline,
            rows: []
        )
    }
}

public struct ClaudeCodeUsageSnapshot: Equatable {
    public let lastComputedDate: String?
    public let today: ClaudeCodeDailyActivity?
    public let totalSessions: Int
    public let totalMessages: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCacheReadTokens: Int
    public let totalCacheCreationTokens: Int
    public let totalWebSearchRequests: Int
    public let totalCostUSD: Double
    public let topModelName: String?

    public func makeSection(refreshedAt: Date) -> AnalyticsSection {
        let todaySummary: String
        if let today {
            todaySummary = "\(today.sessionCount) sessions • \(today.toolCallCount) tools"
        } else {
            todaySummary = "No recent activity"
        }

        let totalTokens = totalInputTokens + totalOutputTokens
        let modelSummary = topModelName ?? "No model data"

        return AnalyticsSection(
            id: "claude-code-local",
            provider: .claudeCode,
            title: "Claude Code",
            subtitle: "Local desktop analytics",
            freshness: .local,
            rows: [
                AnalyticsMetricRow(
                    title: "Today",
                    value: "\(today?.messageCount ?? 0) msgs",
                    subtitle: todaySummary
                ),
                AnalyticsMetricRow(
                    title: "Tokens",
                    value: abbreviatedCount(totalTokens),
                    subtitle: modelSummary
                ),
                AnalyticsMetricRow(
                    title: "Lifetime",
                    value: "\(totalMessages) msgs",
                    subtitle: "\(totalSessions) sessions"
                )
            ],
            message: lastComputedDate.map { "Updated from local cache \($0)" }
        )
    }
}

public struct ClaudeCodeDailyActivity: Equatable {
    public let date: String
    public let messageCount: Int
    public let sessionCount: Int
    public let toolCallCount: Int

    public init(date: String, messageCount: Int, sessionCount: Int, toolCallCount: Int) {
        self.date = date
        self.messageCount = messageCount
        self.sessionCount = sessionCount
        self.toolCallCount = toolCallCount
    }
}

public enum ClaudeCodeUsageReader {
    public static var defaultStatsCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/stats-cache.json", directoryHint: .notDirectory)
    }

    public static func snapshot(fromJSON json: String) -> ClaudeCodeUsageSnapshot? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        guard let root = try? decoder.decode(ClaudeStatsCache.self, from: data) else {
            return nil
        }

        let today = root.dailyActivity.max(by: { $0.date < $1.date })
        let modelPairs = root.modelUsage.map { ($0.key, $0.value) }
        let topModel = modelPairs.max { lhs, rhs in
            lhs.1.totalTokens < rhs.1.totalTokens
        }

        return ClaudeCodeUsageSnapshot(
            lastComputedDate: root.lastComputedDate,
            today: today.map {
                ClaudeCodeDailyActivity(
                    date: $0.date,
                    messageCount: $0.messageCount,
                    sessionCount: $0.sessionCount,
                    toolCallCount: $0.toolCallCount
                )
            },
            totalSessions: root.totalSessions,
            totalMessages: root.totalMessages,
            totalInputTokens: modelPairs.reduce(0) { $0 + $1.1.inputTokens },
            totalOutputTokens: modelPairs.reduce(0) { $0 + $1.1.outputTokens },
            totalCacheReadTokens: modelPairs.reduce(0) { $0 + $1.1.cacheReadInputTokens },
            totalCacheCreationTokens: modelPairs.reduce(0) { $0 + $1.1.cacheCreationInputTokens },
            totalWebSearchRequests: modelPairs.reduce(0) { $0 + $1.1.webSearchRequests },
            totalCostUSD: modelPairs.reduce(0) { $0 + $1.1.costUSD },
            topModelName: topModel?.0
        )
    }

    public static func latestSnapshot(at url: URL = defaultStatsCacheURL) -> ClaudeCodeUsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return snapshot(fromJSON: String(decoding: data, as: UTF8.self))
    }
}

public struct OpenAIAPIUsageSnapshot: Equatable {
    public let totalRequests: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCostUSD: Double
    public let keySummaries: [OpenAIAPIKeySummary]
}

public struct OpenAIAPIKeySummary: Equatable {
    public let apiKeyID: String
    public let requestCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double
}

    public enum OpenAIAPIUsageParser {
        public static func snapshot(usageJSON: String, costJSON: String? = nil) -> OpenAIAPIUsageSnapshot? {
            let decoder = JSONDecoder()
            guard let usageData = usageJSON.data(using: .utf8),
                  let usageRoot = try? decoder.decode(OpenAIUsageBuckets.self, from: usageData) else {
                return nil
            }

            var totals = OpenAIAPIUsageSnapshot(
                totalRequests: 0,
                totalInputTokens: 0,
                totalOutputTokens: 0,
                totalCostUSD: 0,
                keySummaries: []
            )
            var keys: [String: OpenAIAPIKeySummary] = [:]

            for bucket in usageRoot.data {
                for result in bucket.results {
                    totals = OpenAIAPIUsageSnapshot(
                        totalRequests: totals.totalRequests + result.numModelRequests,
                        totalInputTokens: totals.totalInputTokens + result.inputTokens,
                        totalOutputTokens: totals.totalOutputTokens + result.outputTokens,
                        totalCostUSD: totals.totalCostUSD,
                        keySummaries: totals.keySummaries
                    )

                    guard let apiKeyID = result.apiKeyID else {
                        continue
                    }
                    let existing = keys[apiKeyID] ?? OpenAIAPIKeySummary(
                        apiKeyID: apiKeyID,
                        requestCount: 0,
                        inputTokens: 0,
                        outputTokens: 0,
                        costUSD: 0
                    )
                    keys[apiKeyID] = OpenAIAPIKeySummary(
                        apiKeyID: apiKeyID,
                        requestCount: existing.requestCount + result.numModelRequests,
                        inputTokens: existing.inputTokens + result.inputTokens,
                        outputTokens: existing.outputTokens + result.outputTokens,
                        costUSD: existing.costUSD
                    )
                }
            }

            var totalCostUSD = 0.0
            if let costJSON, let costData = costJSON.data(using: .utf8),
               let costRoot = try? decoder.decode(OpenAICostBuckets.self, from: costData) {
                for result in costRoot.data.flatMap(\.results) {
                    let cost = result.amount?.value ?? 0
                    totalCostUSD += cost

                    guard let apiKeyID = result.apiKeyID else {
                        continue
                    }

                    let existing = keys[apiKeyID] ?? OpenAIAPIKeySummary(
                        apiKeyID: apiKeyID,
                        requestCount: 0,
                        inputTokens: 0,
                        outputTokens: 0,
                        costUSD: 0
                    )
                    keys[apiKeyID] = OpenAIAPIKeySummary(
                        apiKeyID: apiKeyID,
                        requestCount: existing.requestCount,
                        inputTokens: existing.inputTokens,
                        outputTokens: existing.outputTokens,
                        costUSD: existing.costUSD + cost
                    )
                }
            }

            return OpenAIAPIUsageSnapshot(
                totalRequests: totals.totalRequests,
                totalInputTokens: totals.totalInputTokens,
                totalOutputTokens: totals.totalOutputTokens,
                totalCostUSD: totalCostUSD,
                keySummaries: keys.values.sorted {
                    if $0.requestCount == $1.requestCount {
                        return $0.inputTokens > $1.inputTokens
                    }
                    return $0.requestCount > $1.requestCount
                }
            )
        }
    }

public struct GenericAPIUsageSnapshot: Equatable {
    public let totalRequests: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCostUSD: Double
    public let keySummaries: [GenericAPIKeySummary]
}

public struct GenericAPIKeySummary: Equatable {
    public let apiKeyID: String
    public let requestCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double
}

public enum GenericAPIUsageParser {
    public static func snapshot(usageJSON: String, costJSON: String? = nil) -> GenericAPIUsageSnapshot? {
        guard let usageData = usageJSON.data(using: .utf8),
              let usageObject = try? JSONSerialization.jsonObject(with: usageData) else {
            return nil
        }

        let usageRows = extractUsageRows(from: usageObject)
        guard !usageRows.isEmpty else {
            return nil
        }

        var totals = GenericAPIUsageSnapshot(
            totalRequests: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCostUSD: 0,
            keySummaries: []
        )
        var keys: [String: GenericAPIKeySummary] = [:]
        var keyCostFromUsage: [String: Double] = [:]
        var keyCountFallback = 1
        var foundMetric = false
        let usageCostKeys = costFieldNames + ["amount.value"]

        for row in usageRows {
            let requestCount = parseInt(from: row, keys: requestCountFieldNames)
            let inputTokens = parseInt(from: row, keys: inputTokenFieldNames)
            let outputTokens = parseInt(from: row, keys: outputTokenFieldNames)
            let rowCost = parseDouble(from: row, keys: usageCostKeys)
            let keyID = parseString(from: row, keys: keyFieldNames) ?? "key_\(keyCountFallback)"

            if requestCount == nil && inputTokens == nil && outputTokens == nil && rowCost == nil {
                continue
            }
            if parseString(from: row, keys: keyFieldNames) == nil {
                keyCountFallback += 1
            }

            foundMetric = true
            let requestCountValue = requestCount ?? 0
            let inputTokensValue = inputTokens ?? 0
            let outputTokensValue = outputTokens ?? 0

            totals = GenericAPIUsageSnapshot(
                totalRequests: totals.totalRequests + requestCountValue,
                totalInputTokens: totals.totalInputTokens + inputTokensValue,
                totalOutputTokens: totals.totalOutputTokens + outputTokensValue,
                totalCostUSD: totals.totalCostUSD,
                keySummaries: totals.keySummaries
            )

            let existing = keys[keyID] ?? GenericAPIKeySummary(
                apiKeyID: keyID,
                requestCount: 0,
                inputTokens: 0,
                outputTokens: 0,
                costUSD: 0
            )
            keys[keyID] = GenericAPIKeySummary(
                apiKeyID: keyID,
                requestCount: existing.requestCount + requestCountValue,
                inputTokens: existing.inputTokens + inputTokensValue,
                outputTokens: existing.outputTokens + outputTokensValue,
                costUSD: existing.costUSD
            )
            keyCostFromUsage[keyID, default: 0] += rowCost ?? 0
        }

        var keyCostFromCosts = [String: Double]()
        var unassignedCost = 0.0
        var hasCostPayload = false
        if let costText = costJSON, let costData = costText.data(using: .utf8) {
            if let costObject = try? JSONSerialization.jsonObject(with: costData) {
                hasCostPayload = true
                for row in extractCostRows(from: costObject) {
                    guard let amount = parseDouble(from: row, keys: costFieldNames + ["amount.value"]) else {
                        continue
                    }
                    if let keyID = parseString(from: row, keys: keyFieldNames) {
                        keyCostFromCosts[keyID, default: 0] += amount
                    } else {
                        unassignedCost += amount
                    }
                }
            }
        }

        guard foundMetric else {
            return nil
        }

        let hasExplicitCostValues = hasCostPayload && (!keyCostFromCosts.isEmpty || unassignedCost > 0)
        var mergedKeys = keys
        for keyID in Set(keys.keys).union(keyCostFromCosts.keys) {
            let existing = mergedKeys[keyID] ?? GenericAPIKeySummary(
                apiKeyID: keyID,
                requestCount: 0,
                inputTokens: 0,
                outputTokens: 0,
                costUSD: 0
            )
            let keyCost = hasExplicitCostValues
                ? (keyCostFromCosts[keyID] ?? keyCostFromUsage[keyID] ?? 0)
                : (keyCostFromUsage[keyID] ?? 0)
            mergedKeys[keyID] = GenericAPIKeySummary(
                apiKeyID: existing.apiKeyID,
                requestCount: existing.requestCount,
                inputTokens: existing.inputTokens,
                outputTokens: existing.outputTokens,
                costUSD: keyCost
            )
        }

        let totalCostUSD = mergedKeys.values.reduce(0, { $0 + $1.costUSD }) + (hasExplicitCostValues ? unassignedCost : 0)
        totals = GenericAPIUsageSnapshot(
            totalRequests: totals.totalRequests,
            totalInputTokens: totals.totalInputTokens,
            totalOutputTokens: totals.totalOutputTokens,
            totalCostUSD: totalCostUSD,
            keySummaries: totals.keySummaries
        )

        return GenericAPIUsageSnapshot(
            totalRequests: totals.totalRequests,
            totalInputTokens: totals.totalInputTokens,
            totalOutputTokens: totals.totalOutputTokens,
            totalCostUSD: totals.totalCostUSD,
            keySummaries: mergedKeys.values.sorted {
                if $0.requestCount == $1.requestCount {
                    if $0.inputTokens == $1.inputTokens {
                        return $0.outputTokens > $1.outputTokens
                    }
                    return $0.inputTokens > $1.inputTokens
                }
                return $0.requestCount > $1.requestCount
            }
        )
    }
}

public struct GenericAPIBalanceSnapshot: Equatable {
    public let currency: String
    public let totalBalance: Double
    public let availableBalance: Double?
    public let grantedBalance: Double?
    public let toppedUpBalance: Double?
    public let creditLimit: Double?
}

public enum GenericAPIBalanceParser {
    public static func snapshot(fromJSON json: String) -> GenericAPIBalanceSnapshot? {
        guard let data = json.data(using: .utf8),
              let rootObject = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let rows = extractBalanceRows(from: rootObject)
        guard !rows.isEmpty else {
            return nil
        }

        let firstMatch = rows.compactMap {
            parseBalanceRow($0)
        }.first

        return firstMatch
    }
}

public struct AnthropicAPIUsageSnapshot: Equatable {
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCacheCreationTokens: Int
    public let totalCacheReadTokens: Int
    public let totalWebSearchRequests: Int
    public let keySummaries: [AnthropicAPIKeySummary]
}

public struct AnthropicAPIKeySummary: Equatable {
    public let apiKeyID: String
    public let inputTokens: Int
    public let outputTokens: Int
}

public enum AnthropicAPIUsageParser {
    public static func snapshot(fromJSON json: String) -> AnthropicAPIUsageSnapshot? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        let rows: [AnthropicUsageRow]
        if let root = try? decoder.decode(AnthropicUsageBucketedReport.self, from: data) {
            rows = root.data.flatMap(\.results)
        } else if let root = try? decoder.decode(AnthropicUsageReport.self, from: data) {
            rows = root.data
        } else {
            return nil
        }

        var keySummaries: [String: AnthropicAPIKeySummary] = [:]
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheCreationTokens = 0
        var totalCacheReadTokens = 0
        var totalWebSearchRequests = 0

        for row in rows {
            totalInputTokens += row.inputTokens
            totalOutputTokens += row.outputTokens
            totalCacheCreationTokens += row.cacheCreationInputTokens
            totalCacheReadTokens += row.cacheReadInputTokens
            totalWebSearchRequests += row.serverToolUse?.webSearchRequests ?? 0

            guard let apiKeyID = row.apiKeyID else {
                continue
            }
            let existing = keySummaries[apiKeyID] ?? AnthropicAPIKeySummary(
                apiKeyID: apiKeyID,
                inputTokens: 0,
                outputTokens: 0
            )
            keySummaries[apiKeyID] = AnthropicAPIKeySummary(
                apiKeyID: apiKeyID,
                inputTokens: existing.inputTokens + row.inputTokens,
                outputTokens: existing.outputTokens + row.outputTokens
            )
        }

        return AnthropicAPIUsageSnapshot(
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheCreationTokens: totalCacheCreationTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            totalWebSearchRequests: totalWebSearchRequests,
            keySummaries: keySummaries.values.sorted {
                if $0.inputTokens == $1.inputTokens {
                    return $0.outputTokens > $1.outputTokens
                }
                return $0.inputTokens > $1.inputTokens
            }
        )
    }
}

public struct DeepSeekBalanceSnapshot: Equatable {
    public let isAvailable: Bool
    public let currency: String
    public let totalBalance: Double
    public let grantedBalance: Double
    public let toppedUpBalance: Double
}

public enum DeepSeekBalanceParser {
    public static func snapshot(fromJSON json: String) -> DeepSeekBalanceSnapshot? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        guard let root = try? decoder.decode(DeepSeekBalanceResponse.self, from: data),
              let balance = root.balanceInfos.first else {
            return nil
        }

        return DeepSeekBalanceSnapshot(
            isAvailable: root.isAvailable,
            currency: balance.currency,
            totalBalance: balance.totalBalance.decimalValue,
            grantedBalance: balance.grantedBalance.decimalValue,
            toppedUpBalance: balance.toppedUpBalance.decimalValue
        )
    }
}

private struct ClaudeStatsCache: Decodable {
    let lastComputedDate: String?
    let dailyActivity: [ClaudeStatsActivity]
    let modelUsage: [String: ClaudeStatsModelUsage]
    let totalSessions: Int
    let totalMessages: Int
}

private struct ClaudeStatsActivity: Decodable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

private struct ClaudeStatsModelUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let webSearchRequests: Int
    let costUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }
}

private struct OpenAIUsageBuckets: Decodable {
    let data: [OpenAIUsageBucket]
}

private struct OpenAIUsageBucket: Decodable {
    let results: [OpenAIUsageResult]
}

private struct OpenAIUsageResult: Decodable {
    let apiKeyID: String?
    let numModelRequests: Int
    let inputTokens: Int
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case apiKeyID = "api_key_id"
        case numModelRequests = "num_model_requests"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct OpenAICostBuckets: Decodable {
    let data: [OpenAICostBucket]
}

private struct OpenAICostBucket: Decodable {
    let results: [OpenAICostResult]
}

private struct OpenAICostResult: Decodable {
    let amount: OpenAICostAmount?
    let apiKeyID: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case apiKeyID = "api_key_id"
    }
}

private struct OpenAICostAmount: Decodable {
    let value: Double
}

private struct AnthropicUsageReport: Decodable {
    let data: [AnthropicUsageRow]
}

private struct AnthropicUsageBucketedReport: Decodable {
    let data: [AnthropicUsageBucket]
}

private struct AnthropicUsageBucket: Decodable {
    let results: [AnthropicUsageRow]
}

private struct AnthropicUsageRow: Decodable {
    let apiKeyID: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let serverToolUse: AnthropicServerToolUse?

    enum CodingKeys: String, CodingKey {
        case apiKeyID = "api_key_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case serverToolUse = "server_tool_use"
    }
}

private struct AnthropicServerToolUse: Decodable {
    let webSearchRequests: Int

    enum CodingKeys: String, CodingKey {
        case webSearchRequests = "web_search_requests"
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct DeepSeekBalanceInfo: Decodable {
    let currency: String
    let totalBalance: DecimalString
    let grantedBalance: DecimalString
    let toppedUpBalance: DecimalString

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

private let keyFieldNames: [String] = [
    "api_key_id",
    "apiKeyId",
    "api_key",
    "key",
    "key_id",
    "workspace_id",
    "project_id",
    "account_id"
]

private let requestCountFieldNames: [String] = [
    "num_model_requests",
    "request_count",
    "requests",
    "num_requests",
    "total_requests"
]

private let inputTokenFieldNames: [String] = [
    "input_tokens",
    "input_token_count",
    "prompt_tokens",
    "input"
]

private let outputTokenFieldNames: [String] = [
    "output_tokens",
    "output_token_count",
    "completion_tokens",
    "output"
]

private let costFieldNames: [String] = [
    "amount",
    "cost",
    "cost_usd",
    "costUsd",
    "costUSD",
    "total_cost",
    "line_cost",
    "usd_cost"
]

private func parseString(from row: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = row[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let value = row[key] as? NSNumber {
            return value.stringValue
        }
    }
    return nil
}

private func parseInt(from row: [String: Any], keys: [String]) -> Int? {
    for key in keys {
        if let value = row[key] {
            if let intValue = value as? Int {
                return intValue
            }
            if let doubleValue = value as? Double {
                return Int(doubleValue)
            }
            if let numberValue = value as? NSNumber {
                return numberValue.intValue
            }
            if let stringValue = value as? String, let parsed = Int(stringValue) {
                return parsed
            }
        }
    }
    return nil
}

private func parseDouble(from row: [String: Any], keys: [String]) -> Double? {
    for key in keys {
        if key.contains(".") {
    let parts = key.split(separator: ".").map(String.init)
    if let nested = nestedValue(in: row, forPath: parts) {
                if let parsed = parseNumeric(nested) {
                    return parsed
                }
            }
            continue
        }
        guard let value = row[key] else {
            continue
        }
        if let parsed = parseNumeric(value) {
            return parsed
        }
    }
    return nil
}

private func parseNumeric(_ value: Any) -> Double? {
    if let doubleValue = value as? Double {
        return doubleValue
    }
    if let intValue = value as? Int {
        return Double(intValue)
    }
    if let numberValue = value as? NSNumber {
        return numberValue.doubleValue
    }
    if let stringValue = value as? String {
        return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
}

private func nestedValue(in object: Any, forPath components: [String]) -> Any? {
    var current: Any = object
    for component in components {
        guard let dict = current as? [String: Any], let next = dict[String(component)] else {
            return nil
        }
        current = next
    }
    return current
}

private func extractUsageRows(from object: Any) -> [[String: Any]] {
    return collectRows(from: object) { dict in
        parseInt(from: dict, keys: inputTokenFieldNames) != nil ||
        parseInt(from: dict, keys: outputTokenFieldNames) != nil ||
        parseInt(from: dict, keys: requestCountFieldNames) != nil ||
        parseDouble(from: dict, keys: costFieldNames + ["amount.value"]) != nil
    }
}

private func extractCostRows(from object: Any) -> [[String: Any]] {
    return collectRows(from: object) { dict in
        parseDouble(from: dict, keys: costFieldNames + ["amount.value"]) != nil
    }
}

private func extractBalanceRows(from object: Any) -> [[String: Any]] {
    return collectRows(from: object) { dict in
        looksLikeBalanceRow(dict)
    }
}

private func collectRows(
    from object: Any,
    matching isRow: ([String: Any]) -> Bool
) -> [[String: Any]] {
    var rows: [[String: Any]] = []

    if let dict = object as? [String: Any] {
        if isRow(dict) {
            rows.append(dict)
        } else {
            for value in dict.values {
                rows.append(contentsOf: collectRows(from: value, matching: isRow))
            }
        }
    } else if let array = object as? [Any] {
        for entry in array {
            if let dict = entry as? [String: Any], isRow(dict) {
                rows.append(dict)
            } else {
                rows.append(contentsOf: collectRows(from: entry, matching: isRow))
            }
        }
    }
    return rows
}

private func looksLikeBalanceRow(_ dict: [String: Any]) -> Bool {
    parseString(
        from: dict,
        keys: ["currency", "curr", "denom", "unit"]
    ) != nil &&
    parseDouble(
        from: dict,
        keys: ["total_balance", "total", "balance", "totalBalance", "available"]
) != nil
}

private func parseBalanceRow(_ row: [String: Any]) -> GenericAPIBalanceSnapshot? {
    guard let currency = parseString(
        from: row,
        keys: ["currency", "curr", "denom", "unit"]
    ) else {
        return nil
    }

    guard let totalBalance = parseDouble(
        from: row,
        keys: ["total_balance", "total", "balance", "totalBalance", "available"]
    ) else {
        return nil
    }

    return GenericAPIBalanceSnapshot(
        currency: currency,
        totalBalance: totalBalance,
        availableBalance: parseDouble(
            from: row,
            keys: ["available_balance", "availableBalance", "remaining_balance", "remainingBalance", "available"]
        ),
        grantedBalance: parseDouble(from: row, keys: ["granted_balance", "granted", "free"]),
        toppedUpBalance: parseDouble(from: row, keys: ["topped_up_balance", "toppedUpBalance", "bonus"]),
        creditLimit: parseDouble(from: row, keys: ["credit_limit", "limit", "quota"])
    )
}

private struct DecimalString: Decodable, Equatable {
    let decimalValue: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let doubleValue = try? container.decode(Double.self) {
            decimalValue = doubleValue
            return
        }

        let stringValue = try container.decode(String.self)
        decimalValue = Double(stringValue) ?? 0
    }
}

private func abbreviatedCount(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM tok", Double(value) / 1_000_000).replacingOccurrences(of: ".0", with: "")
    }
    if value >= 1_000 {
        return String(format: "%.1fk tok", Double(value) / 1_000).replacingOccurrences(of: ".0", with: "")
    }
    return "\(value) tok"
}

private func clampDashboardPercent(_ value: Int) -> Int {
    min(100, max(0, value))
}
