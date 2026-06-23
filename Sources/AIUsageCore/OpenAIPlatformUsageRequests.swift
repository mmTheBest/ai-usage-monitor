import Foundation

public enum OpenAIPlatformUsageRequests {
    public static let defaultCompletionsUsageEndpoint = "https://api.openai.com/v1/organization/usage/completions"
    public static let defaultCostsEndpoint = "https://api.openai.com/v1/organization/costs"

    public static func completionsUsageURL(
        endpoint: String? = nil,
        now: Date = Date(),
        days: Int = 30
    ) -> URL? {
        platformReportURL(
            endpoint: endpoint ?? defaultCompletionsUsageEndpoint,
            now: now,
            days: days,
            includeBucketWidth: true
        )
    }

    public static func costsURL(
        endpoint: String? = nil,
        now: Date = Date(),
        days: Int = 30
    ) -> URL? {
        platformReportURL(
            endpoint: endpoint ?? defaultCostsEndpoint,
            now: now,
            days: days,
            includeBucketWidth: false
        )
    }

    private static func platformReportURL(
        endpoint: String,
        now: Date,
        days: Int,
        includeBucketWidth: Bool
    ) -> URL? {
        guard let baseURL = URL(string: endpoint),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let endTime = Int(now.timeIntervalSince1970)
        let startTime = endTime - max(days, 1) * 24 * 60 * 60
        var queryItems = components.queryItems ?? []

        setQueryItem(name: "start_time", value: "\(startTime)", in: &queryItems)
        setQueryItem(name: "end_time", value: "\(endTime)", in: &queryItems)
        if includeBucketWidth {
            setQueryItem(name: "bucket_width", value: "1d", in: &queryItems)
        }
        setQueryItem(name: "group_by", value: "api_key_id", in: &queryItems)
        setQueryItem(name: "limit", value: "\(max(days, 1))", in: &queryItems)

        components.queryItems = queryItems
        return components.url
    }

    private static func setQueryItem(name: String, value: String, in queryItems: inout [URLQueryItem]) {
        queryItems.removeAll { $0.name == name }
        queryItems.append(URLQueryItem(name: name, value: value))
    }
}

public enum OpenAIPlatformBalanceRows {
    public static func rows(monthlyBudgetUSD: Double?, spentUSD: Double) -> [AnalyticsMetricRow] {
        guard let monthlyBudgetUSD, monthlyBudgetUSD > 0 else {
            return []
        }

        let spent = max(spentUSD, 0)
        let remaining = max(monthlyBudgetUSD - spent, 0)
        return [
            AnalyticsMetricRow(
                title: "Available Balance",
                value: formatUSD(remaining),
                subtitle: "Configured monthly credit minus platform spend"
            ),
            AnalyticsMetricRow(
                title: "Total Balance",
                value: formatUSD(monthlyBudgetUSD),
                subtitle: "Configured monthly credit"
            ),
            AnalyticsMetricRow(
                title: "Spend (USD)",
                value: formatUSD(spent),
                subtitle: "Platform cost report for this period"
            )
        ]
    }

    private static func formatUSD(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
