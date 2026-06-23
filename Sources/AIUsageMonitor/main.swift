import AppKit
import Foundation
import AIUsageCore

private let refreshInterval: TimeInterval = 45
private let savedWindowOriginKey = "AIUsageMonitor.windowOrigin"
private let defaultSideOffset: CGFloat = 20
private let defaultTopOffsetBelowCalendar: CGFloat = 322
private let defaultMaxKeyRows = 8
private typealias ConfiguredAccount = AnalyticsAccountConfiguration

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSPanel?
    private var usageView: MultiSectionUsagePanelView?
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var currentSections: [AnalyticsSection] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let initialSize = DashboardWindowLayout.preferredSize(forSections: [])
        let usageView = MultiSectionUsagePanelView(frame: NSRect(origin: .zero, size: initialSize))
        usageView.onRefresh = { [weak self] in
            self?.refreshUsage()
        }
        usageView.onConfigure = { [weak self] in
            self?.openAccountSetup()
        }

        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = usageView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let desktopLevel = DesktopWidgetPolicy.windowLevelRawValue(
            desktopIconLevel: Int(CGWindowLevelForKey(.desktopIconWindow))
        )
        window.level = NSWindow.Level(rawValue: desktopLevel)
        window.delegate = self

        self.window = window
        self.usageView = usageView

        positionWindow()
        refreshUsage()

        refreshTimer = Timer.scheduledTimer(
            timeInterval: refreshInterval,
            target: self,
            selector: #selector(refreshUsageFromTimer),
            userInfo: nil,
            repeats: true
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let origin = window?.frame.origin else {
            return
        }
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: savedWindowOriginKey)
    }

    @objc private func refreshUsageFromTimer(_ timer: Timer) {
        refreshUsage()
    }

    private func refreshUsage() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        usageView?.showLoading("Refreshing analytics...")

        Task {
            let sections = await Self.resolveSections()
            await MainActor.run {
                self.isRefreshing = false
                self.currentSections = sections
                self.apply(sections: sections)
            }
        }
    }

    private func apply(sections: [AnalyticsSection]) {
        guard AnalyticsSection.shouldShowUsageWindow(for: sections) else {
            window?.orderOut(nil)
            return
        }

        usageView?.apply(sections: sections)
        let preferred = idealWindowSize(for: sections)
        if let window {
            let currentFrame = window.frame
            let newFrame = DashboardWindowLayout.framePreservingTopLeft(
                from: currentFrame,
                preferredSize: preferred
            )
            window.setFrame(newFrame, display: true, animate: false)
            ensureWindowOnScreen()
            window.orderFront(nil)
        }
    }

    private func openAccountSetup() {
        do {
            let wrapperURL = try Self.ensureTerminalSetupWrapper()
            if let terminalURL = Self.terminalApplicationURL() {
                NSWorkspace.shared.open(
                    [wrapperURL],
                    withApplicationAt: terminalURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } else {
                NSWorkspace.shared.open(wrapperURL)
            }
            usageView?.showLoading("Account setup opened in Terminal")
        } catch {
            usageView?.showLoading("Could not open account setup")
        }
    }

    private func positionWindow() {
        let size = idealWindowSize(for: currentSections)
        if let savedValue = UserDefaults.standard.string(forKey: savedWindowOriginKey) {
            let savedOrigin = NSPointFromString(savedValue)
            if originIsVisible(savedOrigin, for: size) {
                window?.setFrameOrigin(savedOrigin)
                return
            }
        }

        guard let screen = NSScreen.main else {
            window?.setFrameOrigin(NSPoint(x: defaultSideOffset, y: 600))
            return
        }

        let visible = screen.visibleFrame
        let x = visible.minX + defaultSideOffset
        let yFromTop = visible.maxY - defaultTopOffsetBelowCalendar
        let y = max(visible.minY + defaultSideOffset, yFromTop - size.height)
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func idealWindowSize(for sections: [AnalyticsSection]) -> CGSize {
        DashboardWindowLayout.preferredSize(forSections: sections)
    }

    private func ensureWindowOnScreen() {
        guard let size = window?.frame.size else {
            return
        }

        if let frameOrigin = window?.frame.origin,
           !originIsVisible(frameOrigin, for: size),
           NSScreen.main != nil {
            positionWindow()
        }
    }

    private func originIsVisible(_ origin: NSPoint, for size: NSSize) -> Bool {
        NSScreen.screens.contains { screen in
            screen.visibleFrame.insetBy(dx: -size.width, dy: -size.height).contains(origin)
        }
    }

    nonisolated private static func resolveSections() async -> [AnalyticsSection] {
        let accounts = loadConfiguredAccounts()
        guard !accounts.isEmpty else {
            return [
                AnalyticsSection(
                    id: "empty",
                    provider: .codex,
                    title: "No Accounts",
                    subtitle: "Nothing configured",
                    freshness: .offline,
                    rows: [
                        AnalyticsMetricRow(
                            title: "Configure",
                            value: "Setup needed",
                            subtitle: "Use the slider button to add subscriptions or API providers"
                        )
                    ],
                    message: nil
                )
            ]
        }

        var sections: [AnalyticsSection] = []
        for account in accounts {
            guard let providerKind = account.providerKind else {
                sections.append(unsupportedProviderSection(account: account))
                continue
            }

            switch providerKind {
            case .codex:
                if let section = await resolveCodexSection() {
                    sections.append(section)
                }
            case .claudeCode:
                sections.append(await resolveClaudeCodeSection(label: account.label))
            case .openAIAPI:
                if let section = await resolveOpenAIAPISection(account: account) {
                    sections.append(section)
                }
            case .anthropicAPI:
                if let section = await resolveAnthropicAPISection(account: account) {
                    sections.append(section)
                }
            case .deepseekAPI, .deepseek:
                if let section = await resolveDeepSeekAPISection(account: account) {
                    sections.append(section)
                }
            case .googleAIAPI, .gemini:
                if let section = await resolveGenericAPISubscriptionSection(
                    provider: .googleAIAPI,
                    account: account,
                    maxKeyRows: defaultMaxKeyRows
                ) {
                    sections.append(section)
                }
            case .glm, .glmAPI:
                if let section = await resolveGenericAPISubscriptionSection(
                    provider: .glmAPI,
                    account: account,
                    maxKeyRows: defaultMaxKeyRows
                ) {
                    sections.append(section)
                }
            }
        }

        let displayableSections = AnalyticsSection.displayableUsageSections(from: sections)
        if displayableSections.isEmpty {
            return []
        }

        return displayableSections
    }

    nonisolated private static func loadConfiguredAccounts() -> [ConfiguredAccount] {
        let configURL = accountsConfigurationURL

        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL) else {
            return []
        }

        guard let file = try? JSONDecoder().decode(AnalyticsAccountsConfigurationFile.self, from: data) else {
            return []
        }

        return file.enabledAccounts
    }

    nonisolated private static var accountsConfigurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/AIUsageMonitor/accounts.json", directoryHint: .notDirectory)
    }

    nonisolated private static func ensureAccountsConfigurationFile() throws -> URL {
        let url = accountsConfigurationURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: url.path) {
            try AnalyticsAccountsConfigurationFile.exampleJSON.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        }

        return url
    }

    nonisolated private static func ensureTerminalSetupWrapper() throws -> URL {
        let setupScriptURL = try existingSetupScriptURL()
        let supportDirectory = accountsConfigurationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )

        let wrapperURL = supportDirectory.appendingPathComponent(SetupAssistantScript.terminalWrapperFileName)
        try SetupAssistantScript.terminalWrapperContents(setupScriptURL: setupScriptURL).write(
            to: wrapperURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapperURL.path
        )
        return wrapperURL
    }

    private static func terminalApplicationURL() -> URL? {
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            return terminalURL
        }

        let fallbackURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil
    }

    nonisolated private static func existingSetupScriptURL() throws -> URL {
        let candidates = SetupAssistantScript.setupScriptCandidates(
            resourceURL: Bundle.main.resourceURL,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )

        if let scriptURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return scriptURL
        }

        throw URLError(.fileDoesNotExist)
    }


    nonisolated private static func resolveCodexSection() async -> AnalyticsSection? {
        let refreshedAt = Date()
        let fallbackSnapshot = try? CodexUsageReader.latestSnapshot()
        let status: CodexUsageStatus
        do {
            let client = try CodexAppServerClient()
            status = try client.fetchUsageStatus(fallbackSnapshot: fallbackSnapshot)
        } catch {
            status = CodexUsageStatus(
                account: nil,
                snapshot: fallbackSnapshot,
                freshness: fallbackSnapshot == nil ? .unavailable : .localEvent,
                refreshedAt: refreshedAt,
                requiresLogin: fallbackSnapshot == nil,
                message: String(describing: error)
            )
        }

        guard status.hasAuthenticatedUsage else {
            return nil
        }

        let title = status.account?.planType.flatMap { "Codex (\($0))" } ?? "Codex"
        let subtitle = status.freshness == .live ? "Live usage from Codex app-server" : "Fallback from local event logs"
        var rows: [AnalyticsMetricRow] = []

        if let snapshot = status.snapshot {
            rows.append(contentsOf: CodexUsageDashboardRows.limitRows(for: snapshot))
            rows.append(AnalyticsMetricRow(
                title: "Account",
                value: status.account?.email ?? "Unknown"
            ))
        }

        if rows.isEmpty {
            rows.append(AnalyticsMetricRow(
                title: "Usage",
                value: status.requiresLogin ? "Login needed" : "Unavailable",
                subtitle: status.message ?? "No Codex data available"
            ))
        }

        let refreshLabel = status.requiresLogin ? "Sign in needed" : "Last updated \(timeLabel(refreshedAt))"
        return analyticsSection(
            id: "codex",
            title: title,
            provider: .codex,
            subtitle: subtitle,
            freshness: status.freshness == .live ? .live : .local,
            rows: rows,
            message: refreshLabel
        )
    }

    nonisolated private static func resolveClaudeCodeSection(label: String?) async -> AnalyticsSection {
        guard let snapshot = ClaudeCodeUsageReader.latestSnapshot() else {
            return analyticsSection(
                id: "claude-code",
                title: label ?? "Claude Code",
                provider: .claudeCode,
                subtitle: "Usage file not found",
                freshness: .offline,
                rows: [
                    AnalyticsMetricRow(
                        title: "Status",
                        value: "No Local Cache",
                        subtitle: "Install or run Claude CLI on this machine"
                    )
                ]
            )
        }

        return snapshot.makeSection(refreshedAt: Date())
    }

    nonisolated private static func resolveOpenAIAPISection(account: ConfiguredAccount) async -> AnalyticsSection? {
        guard let platformCredential = account.effectivePlatformCredential else {
            return analyticsSection(
                id: account.id,
                title: account.label ?? "OpenAI API",
                provider: .openAIAPI,
                subtitle: "Missing developer-platform credential",
                freshness: .offline,
                rows: [
                    AnalyticsMetricRow(
                        title: "Status",
                        value: "Setup needed",
                        subtitle: "Use an organization/admin usage credential, not a single application key"
                    )
                ]
            )
        }

        let now = Date()
        guard let usageURL = OpenAIPlatformUsageRequests.completionsUsageURL(
            endpoint: account.usageEndpoint,
            now: now
        ) else {
            return analyticsSection(
                id: account.id,
                title: account.label ?? "OpenAI API",
                provider: .openAIAPI,
                subtitle: "Invalid usage endpoint",
                freshness: .offline,
                rows: []
            )
        }

        let usageText = try? await requestJSON(url: usageURL, apiKey: platformCredential)
        var costText: String?
        if let costURL = OpenAIPlatformUsageRequests.costsURL(
            endpoint: account.costEndpoint,
            now: now
        ) {
            costText = try? await requestJSON(url: costURL, apiKey: platformCredential)
        }

        var rows: [AnalyticsMetricRow] = []

        if let usageText,
           let snapshot = OpenAIAPIUsageParser.snapshot(usageJSON: usageText, costJSON: costText) {
            rows.append(AnalyticsMetricRow(
                title: "Requests",
                value: "\(snapshot.totalRequests)"
            ))
            rows.append(AnalyticsMetricRow(
                title: "Tokens",
                value: "\(snapshot.totalInputTokens + snapshot.totalOutputTokens)",
                subtitle: "Input: \(snapshot.totalInputTokens) • Output: \(snapshot.totalOutputTokens)"
            ))
            if snapshot.totalCostUSD > 0 {
                rows.append(AnalyticsMetricRow(
                    title: "Cost (USD)",
                    value: formatUSD(snapshot.totalCostUSD)
                ))
            }
            rows.append(contentsOf: OpenAIPlatformBalanceRows.rows(
                monthlyBudgetUSD: account.monthlyBudgetUSD,
                spentUSD: snapshot.totalCostUSD
            ))

            for key in snapshot.keySummaries.prefix(defaultMaxKeyRows) {
                var keyParts: [String] = [
                    "Input \(key.inputTokens)",
                    "Output \(key.outputTokens)"
                ]
                if key.costUSD > 0 {
                    keyParts.append(formatUSD(key.costUSD))
                }
                rows.append(AnalyticsMetricRow(
                    title: "Key \(shortKeyLabel(key.apiKeyID))",
                    value: "\(key.requestCount) req",
                    subtitle: keyParts.joined(separator: " • ")
                ))
            }
        }

        if let balanceEndpoint = account.balanceEndpoint, let balanceURL = URL(string: balanceEndpoint) {
            let balanceText = try? await requestJSON(url: balanceURL, apiKey: platformCredential)
            if let balanceText,
               let balance = GenericAPIBalanceParser.snapshot(fromJSON: balanceText) {
                appendBalanceRows(balance: balance, to: &rows)
            }
        }

        if rows.isEmpty {
            return analyticsSection(
                id: account.id,
                title: account.label ?? "OpenAI API",
                provider: .openAIAPI,
                subtitle: account.usageEndpoint ?? "OpenAI organization usage",
                freshness: .offline,
                rows: [
                    AnalyticsMetricRow(
                        title: "Status",
                        value: "Unavailable",
                        subtitle: "The platform usage report did not return account-level key usage"
                    )
                ],
                message: "Check platform credential permissions"
            )
        }

        return analyticsSection(
            id: account.id,
            title: account.label ?? "OpenAI API",
            provider: .openAIAPI,
            subtitle: "Organization usage by API key",
            freshness: .live,
            rows: rows,
            message: "Updated \(timeLabel(now))"
        )
    }

    nonisolated private static func resolveAnthropicAPISection(account: ConfiguredAccount) async -> AnalyticsSection? {
        guard
            let apiKey = account.effectivePlatformCredential,
            let endpoint = account.usageEndpoint,
            let usageURL = URL(string: endpoint)
        else {
            return analyticsSection(
                id: account.id,
                title: account.label ?? "Anthropic API",
                provider: .anthropicAPI,
                subtitle: "Missing developer-platform credential or endpoint",
                freshness: .offline,
                rows: []
            )
        }

        let usageText = try? await requestJSON(url: usageURL, apiKey: apiKey, additionalHeaders: ["anthropic-version": "2023-06-01"])
        guard
            let usageText,
            let snapshot = AnthropicAPIUsageParser.snapshot(fromJSON: usageText)
        else {
            return analyticsSection(
                id: account.id,
                title: account.label ?? "Anthropic API",
                provider: .anthropicAPI,
                subtitle: account.usageEndpoint ?? "Anthropic API usage",
                freshness: .offline,
                rows: [
                    AnalyticsMetricRow(
                        title: "Status",
                        value: "Unavailable",
                        subtitle: "The endpoint did not return a supported report"
                    )
                ],
                message: "Check credential permissions"
            )
        }

        var rows: [AnalyticsMetricRow] = [
            AnalyticsMetricRow(
                title: "Tokens",
                value: "\(snapshot.totalInputTokens + snapshot.totalOutputTokens)",
                subtitle: "Input \(snapshot.totalInputTokens), Output \(snapshot.totalOutputTokens)"
            ),
            AnalyticsMetricRow(
                title: "Cache",
                value: "\(snapshot.totalCacheCreationTokens + snapshot.totalCacheReadTokens)",
                subtitle: "Creation \(snapshot.totalCacheCreationTokens), Read \(snapshot.totalCacheReadTokens)"
            ),
            AnalyticsMetricRow(
                title: "Web Search",
                value: "\(snapshot.totalWebSearchRequests)"
            )
        ]

        for key in snapshot.keySummaries.prefix(defaultMaxKeyRows) {
            rows.append(AnalyticsMetricRow(
                title: "Key \(shortKeyLabel(key.apiKeyID))",
                value: "Input \(key.inputTokens)",
                subtitle: "Output \(key.outputTokens)"
            ))
        }

        return analyticsSection(
            id: account.id,
            title: account.label ?? "Anthropic API",
            provider: .anthropicAPI,
            subtitle: "API usage by keys",
            freshness: .live,
            rows: rows,
            message: "Updated \(timeLabel(Date()))"
        )
    }

    nonisolated private static func resolveDeepSeekAPISection(account: ConfiguredAccount) async -> AnalyticsSection? {
        guard let apiKey = account.effectivePlatformCredential else {
            return analyticsSection(
                id: account.id,
                title: account.label ?? "DeepSeek API",
                provider: .deepseekAPI,
                subtitle: "Missing developer-platform credential",
                freshness: .offline,
                rows: []
            )
        }

        var rows: [AnalyticsMetricRow] = []

        if let usageEndpoint = account.usageEndpoint, let usageURL = URL(string: usageEndpoint) {
            if let usageText = try? await requestJSON(url: usageURL, apiKey: apiKey),
               let usageSnapshot = GenericAPIUsageParser.snapshot(usageJSON: usageText) {
                rows.append(AnalyticsMetricRow(
                    title: "Requests",
                    value: "\(usageSnapshot.totalRequests)"
                ))
                rows.append(AnalyticsMetricRow(
                    title: "Tokens",
                    value: "\(usageSnapshot.totalInputTokens + usageSnapshot.totalOutputTokens)",
                    subtitle: "Input \(usageSnapshot.totalInputTokens), Output \(usageSnapshot.totalOutputTokens)"
                ))

                if usageSnapshot.totalCostUSD > 0 {
                    rows.append(AnalyticsMetricRow(
                        title: "Cost (USD)",
                        value: formatUSD(usageSnapshot.totalCostUSD)
                    ))
                }

                for key in usageSnapshot.keySummaries.prefix(defaultMaxKeyRows) {
                    rows.append(AnalyticsMetricRow(
                        title: "Key \(shortKeyLabel(key.apiKeyID))",
                        value: "\(key.requestCount) req",
                        subtitle: "Input \(key.inputTokens), Output \(key.outputTokens)" + (key.costUSD > 0 ? " • \(formatUSD(key.costUSD))" : "")
                    ))
                }
            }
        }

        if let balanceEndpoint = account.balanceEndpoint, let balanceURL = URL(string: balanceEndpoint) {
            if let balanceText = try? await requestJSON(url: balanceURL, apiKey: apiKey),
               let snapshot = DeepSeekBalanceParser.snapshot(fromJSON: balanceText) {
                appendBalanceRows(
                    currency: snapshot.currency,
                    totalBalance: snapshot.totalBalance,
                    availableBalance: nil,
                    grantedBalance: snapshot.grantedBalance,
                    toppedUpBalance: snapshot.toppedUpBalance,
                    creditLimit: nil,
                    to: &rows
                )
            }
        }

        if rows.isEmpty {
            return analyticsSection(
                id: account.id,
                title: account.label ?? "DeepSeek API",
                provider: .deepseekAPI,
                subtitle: "Balance and usage",
                freshness: .offline,
                rows: [
                    AnalyticsMetricRow(
                        title: "Status",
                        value: "Unavailable",
                        subtitle: "Add usageEndpoint and/or balanceEndpoint, then check endpoint access"
                    )
                ],
                message: "No usage or balance data returned"
            )
        }

        return analyticsSection(
            id: account.id,
            title: account.label ?? "DeepSeek API",
            provider: .deepseekAPI,
            subtitle: "Balance and usage",
            freshness: .live,
            rows: rows,
            message: "Updated \(timeLabel(Date()))"
        )
    }

    nonisolated private static func resolveGenericAPISubscriptionSection(
        provider: AnalyticsProvider,
        account: ConfiguredAccount,
        maxKeyRows: Int
    ) async -> AnalyticsSection? {
        guard let apiKey = account.effectivePlatformCredential else {
            return analyticsSection(
                id: account.id,
                title: account.label ?? provider.displayName,
                provider: provider,
                subtitle: "Missing developer-platform credential",
                freshness: .offline,
                rows: [
                    AnalyticsMetricRow(
                        title: "Status",
                        value: "Unavailable",
                        subtitle: "Run setup and add a developer-platform usage credential"
                    )
                ]
            )
        }

        var rows: [AnalyticsMetricRow] = []

        if let usageEndpoint = account.usageEndpoint, let usageURL = URL(string: usageEndpoint) {
            let usageText = try? await requestJSON(url: usageURL, apiKey: apiKey)
            var costText: String?
            if let costEndpoint = account.costEndpoint,
               let costURL = URL(string: costEndpoint) {
                costText = try? await requestJSON(url: costURL, apiKey: apiKey)
            }

            if let usageText {
                if let usageSnapshot = GenericAPIUsageParser.snapshot(
                    usageJSON: usageText,
                    costJSON: costText
                ) {
                    let totalCost = formatUSD(usageSnapshot.totalCostUSD)
                    rows.append(AnalyticsMetricRow(
                        title: "Requests",
                        value: "\(usageSnapshot.totalRequests)"
                    ))
                    rows.append(AnalyticsMetricRow(
                        title: "Tokens",
                        value: "\(usageSnapshot.totalInputTokens + usageSnapshot.totalOutputTokens)",
                        subtitle: "Input \(usageSnapshot.totalInputTokens), Output \(usageSnapshot.totalOutputTokens)"
                    ))
                    if usageSnapshot.totalCostUSD > 0 {
                        rows.append(AnalyticsMetricRow(
                            title: "Cost (USD)",
                            value: totalCost
                        ))
                    }

                    for key in usageSnapshot.keySummaries.prefix(maxKeyRows) {
                        var subtitleParts: [String] = [
                            "Requests \(key.requestCount)",
                            "Input \(key.inputTokens)",
                            "Output \(key.outputTokens)"
                        ]
                        if key.costUSD > 0 {
                            subtitleParts.append(formatUSD(key.costUSD))
                        }
                        rows.append(AnalyticsMetricRow(
                            title: "Key \(shortKeyLabel(key.apiKeyID))",
                            value: "\(key.requestCount) req",
                            subtitle: subtitleParts.joined(separator: " • ")
                        ))
                    }
                }
            }
        }

        if let balanceEndpoint = account.balanceEndpoint, let balanceURL = URL(string: balanceEndpoint) {
            let balanceText = try? await requestJSON(url: balanceURL, apiKey: apiKey)
            if let balanceText,
               let balance = GenericAPIBalanceParser.snapshot(fromJSON: balanceText) {
                appendBalanceRows(balance: balance, to: &rows)
            }
        }

        if rows.isEmpty {
            let usageConfigured = account.usageEndpoint != nil
            let balanceConfigured = account.balanceEndpoint != nil
            let missingConfig = [usageConfigured, balanceConfigured].allSatisfy { $0 == false }

            if missingConfig {
                return analyticsSection(
                    id: account.id,
                    title: account.label ?? provider.displayName,
                    provider: provider,
                    subtitle: "Missing usage or balance endpoint",
                    freshness: .offline,
                    rows: [
                        AnalyticsMetricRow(
                            title: "Status",
                            value: "No analytics data",
                            subtitle: "Configure usageEndpoint and/or balanceEndpoint"
                        )
                    ]
                )
            }

            return analyticsSection(
                id: account.id,
                title: account.label ?? provider.displayName,
                provider: provider,
                subtitle: provider == .googleAIAPI ? "Gemini API" : "API section",
                freshness: .offline,
                rows: [
                    AnalyticsMetricRow(
                        title: "Status",
                        value: "Unavailable",
                        subtitle: "The endpoint did not return a supported payload"
                    )
                ],
                message: "Check endpoint auth and response schema"
            )
        }

        return analyticsSection(
            id: account.id,
            title: account.label ?? provider.displayName,
            provider: provider,
            subtitle: "Usage and balance",
            freshness: .live,
            rows: rows,
            message: "Updated \(timeLabel(Date()))"
        )
    }

    nonisolated private static func appendBalanceRows(balance: GenericAPIBalanceSnapshot, to rows: inout [AnalyticsMetricRow]) {
        appendBalanceRows(
            currency: balance.currency,
            totalBalance: balance.totalBalance,
            availableBalance: balance.availableBalance,
            grantedBalance: balance.grantedBalance,
            toppedUpBalance: balance.toppedUpBalance,
            creditLimit: balance.creditLimit,
            to: &rows
        )
    }

    nonisolated private static func appendBalanceRows(
        currency: String,
        totalBalance: Double,
        availableBalance: Double?,
        grantedBalance: Double?,
        toppedUpBalance: Double?,
        creditLimit: Double?,
        to rows: inout [AnalyticsMetricRow]
    ) {
        rows.append(AnalyticsMetricRow(
            title: "Currency",
            value: currency
        ))
        rows.append(AnalyticsMetricRow(
            title: "Total Balance",
            value: formatUSD(totalBalance)
        ))

        if let available = availableBalance {
            rows.append(AnalyticsMetricRow(
                title: "Available Balance",
                value: formatUSD(available)
            ))
        }
        if let granted = grantedBalance {
            rows.append(AnalyticsMetricRow(
                title: "Granted Balance",
                value: formatUSD(granted)
            ))
        }
        if let toppedUp = toppedUpBalance {
            rows.append(AnalyticsMetricRow(
                title: "Topped-up Balance",
                value: formatUSD(toppedUp)
            ))
        }
        if let limit = creditLimit {
            rows.append(AnalyticsMetricRow(
                title: "Credit Limit",
                value: formatUSD(limit)
            ))
        }
    }

    nonisolated private static func shortKeyLabel(_ key: String) -> String {
        guard key.count > 14 else {
            return key
        }

        let head = key.prefix(6)
        let tail = key.suffix(4)
        return "\(head)…\(tail)"
    }

    nonisolated private static func unsupportedProviderSection(account: ConfiguredAccount) -> AnalyticsSection {
        analyticsSection(
            id: account.id,
            title: account.label ?? "Unknown provider",
            provider: .codex,
            subtitle: "Unsupported provider: \(account.provider)",
            freshness: .unsupported,
            rows: [
                AnalyticsMetricRow(
                    title: "Status",
                    value: "Unsupported",
                    subtitle: "Use one of: codex, claude code, openai/chatgpt, anthropic, gemini, deepseek, glm"
                )
            ],
            message: nil
        )
    }
}

private func requestJSON(
    url: URL,
    apiKey: String,
    additionalHeaders: [String: String] = [:],
    timeout: TimeInterval = 18
) async throws -> String {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (name, value) in additionalHeaders {
        request.setValue(value, forHTTPHeaderField: name)
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
        throw URLError(.badServerResponse)
    }

    guard let text = String(data: data, encoding: .utf8) else {
        throw URLError(.cannotDecodeContentData)
    }

    return text
}

private func analyticsSection(
    id: String,
    title: String,
    provider: AnalyticsProvider,
    subtitle: String,
    freshness: AnalyticsSectionFreshness,
    rows: [AnalyticsMetricRow],
    message: String? = nil
) -> AnalyticsSection {
    AnalyticsSection(
        id: id,
        provider: provider,
        title: title,
        subtitle: subtitle,
        freshness: freshness,
        rows: rows,
        message: message
    )
}

private func timeLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.timeZone = TimeZone.current
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func formatUSD(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
}

@MainActor
final class MultiSectionUsagePanelView: NSVisualEffectView {
    var onRefresh: (() -> Void)?
    var onConfigure: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let configureButton = NSButton()
    private let refreshButton = NSButton()
    private let quitButton = NSButton()
    private let footerLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var sectionViews: [AnalyticsSectionCardView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func showLoading(_ message: String) {
        footerLabel.stringValue = message
        refreshButton.isEnabled = false
    }

    func apply(sections: [AnalyticsSection]) {
        refreshButton.isEnabled = true
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        sectionViews.removeAll()

        for section in sections {
            let sectionView = AnalyticsSectionCardView()
            sectionView.apply(section: section)
            addSectionView(sectionView)
        }

        if sections.isEmpty {
            let sectionView = AnalyticsSectionCardView()
            sectionView.apply(
                section: analyticsSection(
                    id: "empty",
                    title: "No Data",
                    provider: .codex,
                    subtitle: "No analytics available",
                    freshness: .offline,
                    rows: [
                        AnalyticsMetricRow(
                            title: "Status",
                            value: "Nothing returned"
                        )
                    ]
                )
            )
            addSectionView(sectionView)
        }

        footerLabel.stringValue = "Updated \(timeLabel(Date()))"
    }

    private func addSectionView(_ sectionView: AnalyticsSectionCardView) {
        sectionViews.append(sectionView)
        stack.addArrangedSubview(sectionView)
        sectionView.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        sectionView.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }

    private func setup() {
        appearance = NSAppearance(named: .darkAqua)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor

        configureButton.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Set up accounts"
        )
        configureButton.bezelStyle = .rounded
        configureButton.controlSize = .small
        configureButton.imagePosition = .imageOnly
        configureButton.toolTip = "Set up accounts"
        configureButton.target = self
        configureButton.action = #selector(configurePressed)

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.imagePosition = .imageOnly
        refreshButton.toolTip = "Refresh"
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)

        quitButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Quit")
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.imagePosition = .imageOnly
        quitButton.toolTip = "Quit AI Usage Monitor"
        quitButton.target = self
        quitButton.action = #selector(quitPressed)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [spacer, configureButton, refreshButton, quitButton])
        headerStack.spacing = 6
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY

        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: 10, weight: .regular)
        footerLabel.textColor = .tertiaryLabelColor

        let spacerRight = NSView()
        spacerRight.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerStack = NSStackView(views: [footerLabel, spacerRight])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 10

        let rootStack = NSStackView(views: [headerStack, SeparatorView(), stack, SeparatorView(), footerStack])
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.spacing = 10
        rootStack.alignment = .width
        rootStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            configureButton.widthAnchor.constraint(equalToConstant: 28),
            configureButton.heightAnchor.constraint(equalToConstant: 24),
            refreshButton.widthAnchor.constraint(equalToConstant: 28),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),
            quitButton.widthAnchor.constraint(equalToConstant: 28),
            quitButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        footerLabel.stringValue = "Loading analytics..."
        showLoading("Loading analytics...")
    }

    @objc private func refreshPressed() {
        onRefresh?()
    }

    @objc private func configurePressed() {
        onConfigure?()
    }

    @objc private func quitPressed() {
        NSApp.terminate(nil)
    }

}

@MainActor
final class AnalyticsSectionCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let sourceBadge = PillLabel()
    private let rowsStack = NSStackView()
    private let messageLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(section: AnalyticsSection) {
        titleLabel.stringValue = section.title
        subtitleLabel.stringValue = section.subtitle
        sourceBadge.stringValue = sourceBadgeTitle(for: section.freshness)
        sourceBadge.badgeColor = sourceBadgeColor(for: section.freshness)
        sourceBadge.textColor = sourceBadgeTextColor(for: section.freshness)

        rowsStack.arrangedSubviews.forEach { view in
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        messageLabel.isHidden = true
        let displayStyle = AnalyticsSectionPresentation.displayStyle(for: section)
        let usesCustomLayout = displayStyle != .metrics
        titleLabel.isHidden = usesCustomLayout
        subtitleLabel.isHidden = usesCustomLayout
        sourceBadge.isHidden = usesCustomLayout

        switch displayStyle {
        case .subscriptionUsage:
            let usageView = SubscriptionUsageSectionView()
            usageView.apply(section: section)
            rowsStack.addArrangedSubview(usageView)
            usageView.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor).isActive = true
            usageView.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true
        case .apiUsage:
            let apiView = APIUsageSectionView()
            apiView.apply(section: section)
            rowsStack.addArrangedSubview(apiView)
            apiView.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor).isActive = true
            apiView.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true
        case .metrics:
            applyMetricRows(section: section)
        }
    }

    private func applyMetricRows(section: AnalyticsSection) {
        if section.rows.isEmpty {
            messageLabel.isHidden = false
            if let message = section.message, !message.isEmpty {
                messageLabel.stringValue = message
            } else {
                messageLabel.stringValue = "No metrics available"
            }
        } else {
            for row in section.rows {
                let rowView = AnalyticsMetricRowView()
                rowView.apply(row: row)
                rowsStack.addArrangedSubview(rowView)
            }
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 2

        messageLabel.font = .systemFont(ofSize: 11, weight: .regular)
        messageLabel.textColor = .tertiaryLabelColor
        messageLabel.alignment = .left
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byWordWrapping

        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.spacing = 8

        sourceBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        sourceBadge.alignment = .center
        sourceBadge.setContentHuggingPriority(.required, for: .horizontal)

        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.spacing = 8
        container.alignment = .width
        container.detachesHiddenViews = true
        container.addArrangedSubview(sourceBadge)
        container.addArrangedSubview(titleLabel)
        container.addArrangedSubview(subtitleLabel)
        container.addArrangedSubview(rowsStack)
        container.addArrangedSubview(messageLabel)

        addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            rowsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        messageLabel.isHidden = true
    }

    private func sourceBadgeTitle(for freshness: AnalyticsSectionFreshness) -> String {
        switch freshness {
        case .live:
            return "Live"
        case .local:
            return "Local"
        case .offline:
            return "Offline"
        case .unsupported:
            return "Manual"
        }
    }

    private func sourceBadgeColor(for freshness: AnalyticsSectionFreshness) -> NSColor {
        switch freshness {
        case .live:
            return NSColor.systemGreen.withAlphaComponent(0.18)
        case .local:
            return NSColor.systemBlue.withAlphaComponent(0.16)
        case .offline:
            return NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        case .unsupported:
            return NSColor.systemOrange.withAlphaComponent(0.18)
        }
    }

    private func sourceBadgeTextColor(for freshness: AnalyticsSectionFreshness) -> NSColor {
        switch freshness {
        case .live:
            return NSColor.systemGreen
        case .local:
            return NSColor.systemBlue
        case .offline:
            return .secondaryLabelColor
        case .unsupported:
            return NSColor.systemOrange
        }
    }
}

@MainActor
final class SubscriptionUsageSectionView: NSView {
    private let providerIcon = ProviderIconView()
    private let titleLabel = NSTextField(labelWithString: "Usage")
    private let cardsStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(section: AnalyticsSection) {
        providerIcon.apply(provider: section.provider)

        cardsStack.arrangedSubviews.forEach { view in
            cardsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for card in AnalyticsSectionPresentation.subscriptionCards(for: section) {
            let cardView = SubscriptionLimitCardView()
            cardView.apply(card: card, provider: section.provider)
            cardsStack.addArrangedSubview(cardView)
            cardView.leadingAnchor.constraint(equalTo: cardsStack.leadingAnchor).isActive = true
            cardView.trailingAnchor.constraint(equalTo: cardsStack.trailingAnchor).isActive = true
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let leftSlot = NSView()
        let rightSlot = NSView()
        providerIcon.translatesAutoresizingMaskIntoConstraints = false
        leftSlot.addSubview(providerIcon)

        NSLayoutConstraint.activate([
            leftSlot.widthAnchor.constraint(equalToConstant: 48),
            rightSlot.widthAnchor.constraint(equalToConstant: 48),
            providerIcon.leadingAnchor.constraint(equalTo: leftSlot.leadingAnchor),
            providerIcon.centerYAnchor.constraint(equalTo: leftSlot.centerYAnchor),
            providerIcon.widthAnchor.constraint(equalToConstant: 42),
            providerIcon.heightAnchor.constraint(equalToConstant: 42)
        ])

        let headerStack = NSStackView(views: [leftSlot, titleLabel, rightSlot])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8

        cardsStack.orientation = .vertical
        cardsStack.alignment = .width
        cardsStack.spacing = 12
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView(views: [headerStack, cardsStack])
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 12
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerStack.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor)
        ])
    }
}

@MainActor
final class SubscriptionLimitCardView: NSView {
    private let percentageLabel = NSTextField(labelWithString: "")
    private let badgeLabel = PillLabel()
    private let progressBar = UsageProgressBarView()
    private let resetLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(card: SubscriptionUsageCard, provider: AnalyticsProvider) {
        percentageLabel.stringValue = card.percentageText
        badgeLabel.stringValue = card.badgeTitle
        badgeLabel.badgeColor = NSColor.labelColor.withAlphaComponent(0.12)
        badgeLabel.textColor = .labelColor
        progressBar.progressPercent = card.progressPercent
        progressBar.fillColor = accentColor(for: provider).withAlphaComponent(0.76)
        resetLabel.stringValue = card.resetText
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(
            calibratedRed: 0.10,
            green: 0.14,
            blue: 0.12,
            alpha: 0.78
        ).cgColor

        percentageLabel.font = .monospacedDigitSystemFont(ofSize: 31, weight: .medium)
        percentageLabel.textColor = .labelColor
        percentageLabel.alignment = .left
        percentageLabel.maximumNumberOfLines = 1

        badgeLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        badgeLabel.alignment = .center

        progressBar.translatesAutoresizingMaskIntoConstraints = false

        resetLabel.font = .systemFont(ofSize: 17, weight: .regular)
        resetLabel.textColor = .secondaryLabelColor
        resetLabel.alignment = .left
        resetLabel.maximumNumberOfLines = 1
        resetLabel.lineBreakMode = .byTruncatingTail

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [percentageLabel, spacer, badgeLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let rootStack = NSStackView(views: [header, progressBar, resetLabel])
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 10
        rootStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            progressBar.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            resetLabel.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            resetLabel.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 104),
            progressBar.heightAnchor.constraint(equalToConstant: 14)
        ])
    }
}

@MainActor
final class APIUsageSectionView: NSView {
    private let providerIcon = ProviderIconView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let balanceView = APIBalanceSummaryView()
    private let pieChartView = APIKeyPieChartView()
    private let legendStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(section: AnalyticsSection) {
        providerIcon.apply(provider: section.provider)
        titleLabel.stringValue = section.title
        guard let summary = AnalyticsSectionPresentation.apiSummary(for: section) else {
            balanceView.apply(value: "No balance", subtitle: "Balance unavailable")
            pieChartView.apply(slices: [], provider: section.provider)
            return
        }

        balanceView.apply(value: summary.balanceValue, subtitle: summary.balanceSubtitle)
        pieChartView.apply(slices: summary.keySlices, provider: section.provider)

        legendStack.arrangedSubviews.forEach { view in
            legendStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let palette = chartColors(for: section.provider)
        for (index, slice) in summary.keySlices.prefix(4).enumerated() {
            let row = APIKeyLegendRowView()
            row.apply(
                color: palette[index % palette.count],
                label: slice.label,
                value: Int(slice.value.rounded())
            )
            legendStack.addArrangedSubview(row)
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerStack = NSStackView(views: [providerIcon, titleLabel, headerSpacer])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10

        let chartColumn = NSStackView(views: [pieChartView, legendStack])
        chartColumn.orientation = .vertical
        chartColumn.alignment = .centerX
        chartColumn.spacing = 8

        legendStack.orientation = .vertical
        legendStack.alignment = .width
        legendStack.spacing = 5

        let contentStack = NSStackView(views: [balanceView, chartColumn])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 12
        contentStack.distribution = .fillEqually

        let rootStack = NSStackView(views: [headerStack, contentStack])
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 12
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            providerIcon.widthAnchor.constraint(equalToConstant: 32),
            providerIcon.heightAnchor.constraint(equalToConstant: 32),
            pieChartView.widthAnchor.constraint(equalToConstant: 120),
            pieChartView.heightAnchor.constraint(equalToConstant: 120),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 196)
        ])
    }
}

@MainActor
final class APIBalanceSummaryView: NSView {
    private let captionLabel = NSTextField(labelWithString: "Remaining")
    private let valueLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(value: String, subtitle: String) {
        valueLabel.stringValue = value
        subtitleLabel.stringValue = subtitle
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.48).cgColor

        captionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.maximumNumberOfLines = 1

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.maximumNumberOfLines = 1
        valueLabel.lineBreakMode = .byTruncatingMiddle

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping

        let spacer = NSView()
        let rootStack = NSStackView(views: [captionLabel, valueLabel, subtitleLabel, spacer])
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
    }
}

@MainActor
final class APIKeyLegendRowView: NSView {
    private let dotView = ColorDotView()
    private let labelView = NSTextField(labelWithString: "")
    private let valueView = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(color: NSColor, label: String, value: Int) {
        dotView.color = color
        labelView.stringValue = label
        valueView.stringValue = "\(value)"
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        labelView.font = .systemFont(ofSize: 10, weight: .medium)
        labelView.textColor = .secondaryLabelColor
        labelView.lineBreakMode = .byTruncatingMiddle
        valueView.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        valueView.textColor = .tertiaryLabelColor
        valueView.alignment = .right

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [dotView, labelView, spacer, valueView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 14)
        ])
    }
}

@MainActor
final class ColorDotView: NSView {
    var color: NSColor = .systemBlue {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

@MainActor
final class APIKeyPieChartView: NSView {
    private var slices: [APIKeyUsageSlice] = []
    private var colors: [NSColor] = chartColors(for: .openAIAPI)

    func apply(slices: [APIKeyUsageSlice], provider: AnalyticsProvider) {
        self.slices = slices
        self.colors = chartColors(for: provider)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let drawingRect = bounds.insetBy(dx: 6, dy: 6)
        let center = NSPoint(x: drawingRect.midX, y: drawingRect.midY)
        let radius = min(drawingRect.width, drawingRect.height) / 2
        let total = slices.reduce(0) { $0 + $1.value }

        guard total > 0 else {
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            ring.lineWidth = 10
            ring.stroke()
            return
        }

        var startAngle: CGFloat = -90
        for (index, slice) in slices.enumerated() {
            let angle = CGFloat(slice.value / total) * 360
            let endAngle = startAngle + angle
            let path = NSBezierPath()
            path.move(to: center)
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
            path.close()
            colors[index % colors.count].setFill()
            path.fill()
            startAngle = endAngle
        }

        NSColor.windowBackgroundColor.withAlphaComponent(0.86).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius * 0.45,
            y: center.y - radius * 0.45,
            width: radius * 0.9,
            height: radius * 0.9
        )).fill()
    }
}

@MainActor
final class UsageProgressBarView: NSView {
    var progressPercent: Int = 0 {
        didSet {
            needsDisplay = true
        }
    }
    var fillColor: NSColor = .systemGreen {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 2)
        let cornerRadius = rect.height / 2
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        let fillWidth = rect.width * CGFloat(max(0, min(progressPercent, 100))) / 100
        guard fillWidth > 0 else {
            return
        }

        fillColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).fill()
    }
}

@MainActor
final class ProviderIconView: NSView {
    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(provider: AnalyticsProvider) {
        imageView.image = NSImage(
            systemSymbolName: symbolName(for: provider),
            accessibilityDescription: provider.displayName
        )
        imageView.contentTintColor = accentColor(for: provider)
        layer?.backgroundColor = accentColor(for: provider).withAlphaComponent(0.16).cgColor
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.66),
            imageView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.66)
        ])
    }
}

private func symbolName(for provider: AnalyticsProvider) -> String {
    switch provider {
    case .codex:
        return "terminal.fill"
    case .claudeCode:
        return "asterisk"
    case .gemini, .googleAIAPI:
        return "sparkles"
    case .openAIAPI:
        return "bolt.horizontal.circle.fill"
    case .anthropicAPI:
        return "a.circle.fill"
    case .deepseek, .deepseekAPI:
        return "drop.fill"
    case .glm, .glmAPI:
        return "cube.fill"
    }
}

private func accentColor(for provider: AnalyticsProvider) -> NSColor {
    switch provider {
    case .codex:
        return NSColor.systemGreen
    case .claudeCode:
        return NSColor.systemOrange
    case .gemini, .googleAIAPI:
        return NSColor.systemPurple
    case .openAIAPI:
        return NSColor.systemTeal
    case .anthropicAPI:
        return NSColor.systemOrange
    case .deepseek, .deepseekAPI:
        return NSColor.systemBlue
    case .glm, .glmAPI:
        return NSColor.systemPink
    }
}

private func chartColors(for provider: AnalyticsProvider) -> [NSColor] {
    [
        accentColor(for: provider),
        NSColor.systemBlue,
        NSColor.systemOrange,
        NSColor.systemPurple,
        NSColor.systemPink,
        NSColor.systemYellow,
        NSColor.systemMint
    ]
}

@MainActor
final class AnalyticsMetricRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let rowStack = NSStackView()
    private let headerStack = NSStackView()
    private var minimumHeightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(row: AnalyticsMetricRow) {
        titleLabel.stringValue = row.title
        valueLabel.stringValue = row.value
        subtitleLabel.stringValue = row.subtitle ?? ""
        subtitleLabel.isHidden = row.subtitle == nil
        progress.isHidden = row.progressPercent == nil
        if let progressPercent = row.progressPercent {
            progress.doubleValue = Double(progressPercent)
        }
        minimumHeightConstraint?.constant = row.subtitle == nil && row.progressPercent == nil ? 28 : 58
        needsLayout = true
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = 1
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 2

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.style = .bar
        progress.controlSize = .small

        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        subtitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        progress.setContentCompressionResistancePriority(.required, for: .vertical)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.orientation = .horizontal
        headerStack.alignment = .firstBaseline
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(spacer)
        headerStack.addArrangedSubview(valueLabel)

        rowStack.orientation = .vertical
        rowStack.alignment = .width
        rowStack.spacing = 5
        rowStack.detachesHiddenViews = true
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(headerStack)
        rowStack.addArrangedSubview(subtitleLabel)
        rowStack.addArrangedSubview(progress)

        [rowStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(rowStack)

        let minimumHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        self.minimumHeightConstraint = minimumHeightConstraint

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            minimumHeightConstraint,
            progress.heightAnchor.constraint(equalToConstant: 7),
            progress.widthAnchor.constraint(equalTo: rowStack.widthAnchor)
        ])
    }
}

@MainActor
final class PillLabel: NSTextField {
    var badgeColor: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12) {
        didSet {
            layer?.backgroundColor = badgeColor.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isEditable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = .systemFont(ofSize: 11, weight: .semibold)
        textColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = badgeColor.cgColor
        setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }
}

@MainActor
final class SeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
}

@MainActor
func bootstrap() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

bootstrap()
