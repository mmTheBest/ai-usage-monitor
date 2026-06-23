import Foundation

public enum CodexUsageDashboardRows {
    public static func limitRows(for snapshot: UsageSnapshot, now: Date = Date()) -> [AnalyticsMetricRow] {
        [
            quotaRow(for: snapshot.primary, now: now),
            quotaRow(for: snapshot.secondary, now: now)
        ]
    }

    private static func quotaRow(for window: UsageWindow, now: Date) -> AnalyticsMetricRow {
        AnalyticsMetricRow(
            title: limitTitle(forMinutes: window.windowMinutes),
            value: "\(window.remainingPercent)% left",
            subtitle: "\(window.usedPercent)% used | \(resetLabel(for: window, now: now))",
            progressPercent: window.remainingPercent
        )
    }

    private static func limitTitle(forMinutes minutes: Int) -> String {
        switch minutes {
        case 300:
            return "5-hour limit"
        case 10_080:
            return "Weekly limit"
        case 1_440:
            return "Daily limit"
        default:
            if minutes > 0, minutes.isMultiple(of: 1_440) {
                return "\(minutes / 1_440)-day limit"
            }
            if minutes > 0, minutes.isMultiple(of: 60) {
                return "\(minutes / 60)-hour limit"
            }
            return "Usage limit"
        }
    }

    private static func resetLabel(for window: UsageWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else {
            return "No reset time"
        }

        let seconds = Int(resetsAt.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else {
            return "Resets soon"
        }

        return "Resets in \(relativeDurationLabel(seconds: seconds))"
    }

    private static func relativeDurationLabel(seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = max(1, (seconds % 3_600) / 60)

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
