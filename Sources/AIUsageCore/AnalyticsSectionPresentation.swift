import Foundation

public enum AnalyticsSectionDisplayStyle: Equatable {
    case subscriptionUsage
    case apiUsage
    case metrics
}

public struct SubscriptionUsageCard: Equatable {
    public let percentageText: String
    public let badgeTitle: String
    public let detailTitle: String
    public let resetText: String
    public let remainingText: String
    public let progressPercent: Int
}

public struct APIUsageSummary: Equatable {
    public let balanceValue: String
    public let balanceSubtitle: String
    public let totalUsageText: String
    public let keySlices: [APIKeyUsageSlice]
}

public struct APIKeyUsageSlice: Equatable {
    public let label: String
    public let value: Double
    public let detail: String
}

public enum AnalyticsSectionPresentation {
    public static func displayStyle(for section: AnalyticsSection) -> AnalyticsSectionDisplayStyle {
        if !subscriptionCards(for: section).isEmpty && isSubscriptionProvider(section.provider) {
            return .subscriptionUsage
        }

        if isAPIProvider(section.provider), apiSummary(for: section) != nil {
            return .apiUsage
        }

        return .metrics
    }

    public static func subscriptionCards(for section: AnalyticsSection) -> [SubscriptionUsageCard] {
        section.rows.compactMap { row in
            guard let progressPercent = row.progressPercent else {
                return nil
            }

            return SubscriptionUsageCard(
                percentageText: "\(progressPercent)%",
                badgeTitle: limitBadgeTitle(for: row.title),
                detailTitle: row.title,
                resetText: resetText(from: row.subtitle),
                remainingText: row.value,
                progressPercent: progressPercent
            )
        }
    }

    public static func apiSummary(for section: AnalyticsSection) -> APIUsageSummary? {
        let selectedBalanceRow = section.rows.firstBalanceRow(matching: "Available Balance")
            ?? section.rows.firstBalanceRow(matching: "Total Balance")
            ?? section.rows.firstBalanceRow(matching: "Credit Limit")

        let keySlices = section.rows.compactMap(apiKeySlice(from:))
        let totalUsage = keySlices.reduce(0) { $0 + $1.value }
        let totalUsageText = totalUsage > 0
            ? "\(Int(totalUsage.rounded())) key units"
            : "No key usage"

        guard selectedBalanceRow != nil || !keySlices.isEmpty else {
            return nil
        }

        return APIUsageSummary(
            balanceValue: selectedBalanceRow?.value ?? "No balance",
            balanceSubtitle: selectedBalanceRow?.title ?? "Balance unavailable",
            totalUsageText: totalUsageText,
            keySlices: keySlices
        )
    }

    private static func isSubscriptionProvider(_ provider: AnalyticsProvider) -> Bool {
        switch provider {
        case .codex, .claudeCode, .gemini:
            return true
        case .deepseek, .glm, .openAIAPI, .anthropicAPI, .googleAIAPI, .deepseekAPI, .glmAPI:
            return false
        }
    }

    private static func isAPIProvider(_ provider: AnalyticsProvider) -> Bool {
        switch provider {
        case .openAIAPI, .anthropicAPI, .googleAIAPI, .deepseekAPI, .glmAPI:
            return true
        case .codex, .claudeCode, .gemini, .deepseek, .glm:
            return false
        }
    }

    private static func limitBadgeTitle(for title: String) -> String {
        let normalized = title.lowercased()
        if normalized.contains("weekly") {
            return "Weekly"
        }
        if normalized.contains("5-hour") || normalized.contains("5 hour") {
            return "5-hour"
        }
        if normalized.contains("daily") {
            return "Daily"
        }
        if normalized.contains("hour") {
            return title.replacingOccurrences(of: " limit", with: "")
        }
        return title
    }

    private static func resetText(from subtitle: String?) -> String {
        guard let subtitle, !subtitle.isEmpty else {
            return "No reset time"
        }

        let parts = subtitle.components(separatedBy: " | ")
        return parts.last ?? subtitle
    }

    private static func apiKeySlice(from row: AnalyticsMetricRow) -> APIKeyUsageSlice? {
        guard row.title.hasPrefix("Key ") else {
            return nil
        }

        let label = String(row.title.dropFirst(4))
        let value: Double
        if row.value.localizedCaseInsensitiveContains("req"),
           let requestCount = firstNumber(in: row.value) {
            value = requestCount
        } else {
            let fallbackText = [row.value, row.subtitle].compactMap { $0 }.joined(separator: " ")
            value = numbers(in: fallbackText).reduce(0, +)
        }

        guard value > 0 else {
            return nil
        }

        return APIKeyUsageSlice(
            label: label,
            value: value,
            detail: [row.value, row.subtitle].compactMap { $0 }.joined(separator: " | ")
        )
    }

    private static func firstNumber(in text: String) -> Double? {
        numbers(in: text).first
    }

    private static func numbers(in text: String) -> [Double] {
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: "0123456789.").inverted
        var values: [Double] = []

        while !scanner.isAtEnd {
            if let value = scanner.scanDouble() {
                values.append(value)
            } else {
                scanner.currentIndex = text.index(after: scanner.currentIndex)
            }
        }

        return values
    }
}

private extension Array where Element == AnalyticsMetricRow {
    func firstBalanceRow(matching title: String) -> AnalyticsMetricRow? {
        first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
    }
}
