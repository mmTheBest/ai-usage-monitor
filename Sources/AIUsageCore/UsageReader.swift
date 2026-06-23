import Foundation

public struct UsageSnapshot: Equatable {
    public let timestamp: Date?
    public let limitID: String
    public let limitName: String?
    public let primary: UsageWindow
    public let secondary: UsageWindow

    public init(
        timestamp: Date?,
        limitID: String,
        limitName: String?,
        primary: UsageWindow,
        secondary: UsageWindow
    ) {
        self.timestamp = timestamp
        self.limitID = limitID
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
    }
}

public struct UsageWindow: Equatable {
    public let usedPercent: Int
    public let windowMinutes: Int
    public let resetsAt: Date?

    public init(usedPercent: Int, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = clampPercent(usedPercent)
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int {
        clampPercent(100 - usedPercent)
    }
}

public struct CodexAccount: Equatable {
    public let kind: String
    public let email: String?
    public let planType: String?

    public init(kind: String, email: String?, planType: String?) {
        self.kind = kind
        self.email = email
        self.planType = planType
    }
}

public enum UsageFreshness: Equatable {
    case live
    case localEvent
    case unavailable
}

public enum DesktopWidgetPolicy {
    public static func windowLevelRawValue(desktopIconLevel: Int) -> Int {
        desktopIconLevel + 1
    }
}

public struct CodexUsageStatus: Equatable {
    public let account: CodexAccount?
    public let snapshot: UsageSnapshot?
    public let freshness: UsageFreshness
    public let refreshedAt: Date
    public let requiresLogin: Bool
    public let message: String?

    public init(
        account: CodexAccount?,
        snapshot: UsageSnapshot?,
        freshness: UsageFreshness,
        refreshedAt: Date,
        requiresLogin: Bool,
        message: String?
    ) {
        self.account = account
        self.snapshot = snapshot
        self.freshness = freshness
        self.refreshedAt = refreshedAt
        self.requiresLogin = requiresLogin
        self.message = message
    }

    public var hasAuthenticatedUsage: Bool {
        account != nil && snapshot != nil && !requiresLogin
    }
}

public struct CodexLoginStart: Equatable {
    public let loginID: String
    public let authURL: URL

    public init(loginID: String, authURL: URL) {
        self.loginID = loginID
        self.authURL = authURL
    }
}

public enum CodexUsageReader {
    public static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sessions", directoryHint: .isDirectory)
    }

    public static func snapshot(fromJSONLine line: String) -> UsageSnapshot? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any],
              let primaryJSON = rateLimits["primary"] as? [String: Any],
              let secondaryJSON = rateLimits["secondary"] as? [String: Any],
              let primary = logUsageWindow(from: primaryJSON),
              let secondary = logUsageWindow(from: secondaryJSON) else {
            return nil
        }

        let timestamp = (root["timestamp"] as? String).flatMap(parseISODate)

        return UsageSnapshot(
            timestamp: timestamp,
            limitID: rateLimits["limit_id"] as? String ?? "",
            limitName: rateLimits["limit_name"] as? String,
            primary: primary,
            secondary: secondary
        )
    }

    public static func latestSnapshot(
        in sessionsRoot: URL = defaultSessionsRoot,
        maxFilesToScan: Int = 40,
        tailByteCount: UInt64 = 131_072
    ) throws -> UsageSnapshot? {
        let files = try sessionFiles(in: sessionsRoot)
        var snapshots: [UsageSnapshot] = []

        for file in files.prefix(max(0, maxFilesToScan)) {
            let tail = try tailText(from: file, byteCount: tailByteCount)
            for line in tail.split(whereSeparator: \.isNewline).reversed() {
                if let snapshot = snapshot(fromJSONLine: String(line)) {
                    snapshots.append(snapshot)
                    break
                }
            }
        }

        let baseSnapshots = snapshots.filter { $0.limitID == "codex" }
        return newestSnapshot(from: baseSnapshots) ?? newestSnapshot(from: snapshots)
    }

    private static func sessionFiles(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path()) else {
            return []
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else {
                continue
            }
            files.append((url, values.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map(\.url)
    }

    private static func tailText(from file: URL, byteCount: UInt64 = 1_048_576) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let offset = size > byteCount ? size - byteCount : 0
        try handle.seek(toOffset: offset)

        let data = try handle.readToEnd() ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func newestSnapshot(from snapshots: [UsageSnapshot]) -> UsageSnapshot? {
        snapshots.max { left, right in
            (left.timestamp ?? .distantPast) < (right.timestamp ?? .distantPast)
        }
    }
}

public enum CodexAppServerParser {
    public static func usageStatus(
        fromOutput output: String,
        fallbackSnapshot: UsageSnapshot?,
        refreshedAt: Date = Date()
    ) -> CodexUsageStatus {
        let messages = jsonObjects(fromOutput: output)
        let accountResult = responseResult(withID: 2, in: messages)
        let rateLimitResult = responseResult(withID: 3, in: messages)
        let account = accountResult.flatMap(parseAccount)
        let requiresLogin = requiresLogin(from: accountResult)

        if let snapshot = rateLimitResult.flatMap(parseUsageSnapshot) {
            return CodexUsageStatus(
                account: account,
                snapshot: snapshot,
                freshness: .live,
                refreshedAt: refreshedAt,
                requiresLogin: false,
                message: nil
            )
        }

        if let fallbackSnapshot {
            return CodexUsageStatus(
                account: account,
                snapshot: fallbackSnapshot,
                freshness: .localEvent,
                refreshedAt: refreshedAt,
                requiresLogin: requiresLogin,
                message: errorMessage(in: messages) ?? "Live usage is unavailable; showing the last local Codex event."
            )
        }

        return CodexUsageStatus(
            account: account,
            snapshot: nil,
            freshness: .unavailable,
            refreshedAt: refreshedAt,
            requiresLogin: requiresLogin || account == nil,
            message: errorMessage(in: messages) ?? "Sign in to Codex to read live usage."
        )
    }

    public static func loginStart(fromOutput output: String) -> CodexLoginStart? {
        let messages = jsonObjects(fromOutput: output)
        guard let result = responseResult(withID: 2, in: messages),
              let type = result["type"] as? String,
              type == "chatgpt",
              let loginID = result["loginId"] as? String,
              let authURLString = result["authUrl"] as? String,
              let authURL = URL(string: authURLString) else {
            return nil
        }

        return CodexLoginStart(loginID: loginID, authURL: authURL)
    }

    public static func loginCompleted(fromLine line: String) -> (success: Bool, error: String?)? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["method"] as? String == "account/login/completed",
              let params = root["params"] as? [String: Any],
              let success = params["success"] as? Bool else {
            return nil
        }

        return (success: success, error: params["error"] as? String)
    }

    private static func responseResult(withID id: Int, in messages: [[String: Any]]) -> [String: Any]? {
        for message in messages {
            if intValue(message["id"]) == id {
                return message["result"] as? [String: Any]
            }
        }
        return nil
    }

    private static func parseAccount(from result: [String: Any]) -> CodexAccount? {
        guard let account = result["account"] as? [String: Any],
              let kind = account["type"] as? String else {
            return nil
        }

        return CodexAccount(
            kind: kind,
            email: account["email"] as? String,
            planType: account["planType"] as? String
        )
    }

    private static func requiresLogin(from result: [String: Any]?) -> Bool {
        guard let result else {
            return false
        }
        return result["requiresOpenaiAuth"] as? Bool ?? false
    }

    private static func parseUsageSnapshot(from result: [String: Any]) -> UsageSnapshot? {
        let selected: [String: Any]?
        if let byLimitID = result["rateLimitsByLimitId"] as? [String: Any],
           let codexLimit = byLimitID["codex"] as? [String: Any] {
            selected = codexLimit
        } else if let rateLimits = result["rateLimits"] as? [String: Any] {
            selected = rateLimits
        } else {
            selected = nil
        }

        guard let rateLimits = selected,
              let primaryJSON = rateLimits["primary"] as? [String: Any],
              let secondaryJSON = rateLimits["secondary"] as? [String: Any],
              let primary = appServerUsageWindow(from: primaryJSON),
              let secondary = appServerUsageWindow(from: secondaryJSON) else {
            return nil
        }

        return UsageSnapshot(
            timestamp: Date(),
            limitID: rateLimits["limitId"] as? String ?? "codex",
            limitName: rateLimits["limitName"] as? String,
            primary: primary,
            secondary: secondary
        )
    }

    private static func errorMessage(in messages: [[String: Any]]) -> String? {
        for message in messages {
            if let error = message["error"] as? [String: Any] {
                return error["message"] as? String
            }
        }
        return nil
    }

    private static func jsonObjects(fromOutput output: String) -> [[String: Any]] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8) else {
                    return nil
                }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
    }
}

public enum CodexAppServerClientError: Error, CustomStringConvertible {
    case codexExecutableNotFound
    case timedOut
    case processFailed(Int32, String)
    case invalidLoginResponse(String)

    public var description: String {
        switch self {
        case .codexExecutableNotFound:
            return "Could not find the codex executable."
        case .timedOut:
            return "Codex app-server did not respond before the timeout."
        case .processFailed(_, let stderr):
            return stderr.isEmpty ? "Codex app-server failed." : stderr
        case .invalidLoginResponse(let output):
            return output.isEmpty ? "Codex did not return a login URL." : output
        }
    }
}

public final class CodexAppServerClient {
    public let executableURL: URL

    public init(executableURL: URL? = nil) throws {
        if let executableURL {
            self.executableURL = executableURL
        } else if let detectedURL = Self.detectCodexExecutable() {
            self.executableURL = detectedURL
        } else {
            throw CodexAppServerClientError.codexExecutableNotFound
        }
    }

    public func fetchUsageStatus(
        timeout: TimeInterval = 15,
        fallbackSnapshot: UsageSnapshot? = nil
    ) throws -> CodexUsageStatus {
        let output = try runAppServer(
            requests: [
                initializeRequest(id: 1),
                #"{"id":2,"method":"account/read","params":{"refreshToken":false}}"#,
                #"{"id":3,"method":"account/rateLimits/read"}"#
            ],
            expectedResponseID: 3,
            timeout: timeout
        )

        return CodexAppServerParser.usageStatus(
            fromOutput: output,
            fallbackSnapshot: fallbackSnapshot
        )
    }

    public func startLogin(timeout: TimeInterval = 20) throws -> CodexLoginStart {
        let output = try runAppServer(
            requests: [
                initializeRequest(id: 1),
                #"{"id":2,"method":"account/login/start","params":{"type":"chatgpt","codexStreamlinedLogin":true}}"#
            ],
            expectedResponseID: 2,
            timeout: timeout
        )

        guard let loginStart = CodexAppServerParser.loginStart(fromOutput: output) else {
            throw CodexAppServerClientError.invalidLoginResponse(output)
        }

        return loginStart
    }

    public static func detectCodexExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func runAppServer(
        requests: [String],
        expectedResponseID: Int,
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        let state = AppServerRunState()

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            let chunk = String(decoding: data, as: UTF8.self)
            state.appendOutput(chunk, expectedResponseID: expectedResponseID)
        }

        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            state.appendError(String(decoding: data, as: UTF8.self))
        }

        try process.run()

        let requestBody = requests.joined(separator: "\n") + "\n"
        if let data = requestBody.data(using: .utf8) {
            input.fileHandleForWriting.write(data)
        }

        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            state.finish(sawExpected: false)
        }

        if state.wait(timeout: timeout) == .timedOut {
            process.terminate()
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerClientError.timedOut
        }

        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()

        if process.isRunning {
            process.terminate()
        }

        let snapshot = state.snapshot()
        let finalOutput = snapshot.output
        let finalError = snapshot.error
        let didSeeExpected = snapshot.sawExpectedResponse

        if !didSeeExpected, process.terminationStatus != 0 {
            throw CodexAppServerClientError.processFailed(process.terminationStatus, finalError)
        }
        if !didSeeExpected {
            throw CodexAppServerClientError.timedOut
        }

        return finalOutput
    }

    private func initializeRequest(id: Int) -> String {
        """
        {"id":\(id),"method":"initialize","params":{"clientInfo":{"name":"ai-usage-monitor","title":"AI Usage Monitor","version":"1.0.0"},"capabilities":null}}
        """
    }
}

private final class AppServerRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outputText = ""
    private var errorText = ""
    private var sawExpectedResponse = false
    private var didFinish = false

    func appendOutput(_ chunk: String, expectedResponseID: Int) {
        lock.lock()
        outputText.append(chunk)
        let hasExpectedResponse = containsResponse(withID: expectedResponseID, in: outputText)
        lock.unlock()

        if hasExpectedResponse {
            finish(sawExpected: true)
        }
    }

    func appendError(_ chunk: String) {
        lock.lock()
        errorText.append(chunk)
        lock.unlock()
    }

    func finish(sawExpected: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else {
            return
        }
        sawExpectedResponse = sawExpectedResponse || sawExpected
        didFinish = true
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + timeout)
    }

    func snapshot() -> (output: String, error: String, sawExpectedResponse: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (outputText, errorText, sawExpectedResponse)
    }
}

private func logUsageWindow(from json: [String: Any]) -> UsageWindow? {
    guard let usedPercentValue = doubleValue(json["used_percent"]),
          let windowMinutes = intValue(json["window_minutes"]),
          let resetsAt = doubleValue(json["resets_at"]) else {
        return nil
    }

    return UsageWindow(
        usedPercent: Int(usedPercentValue.rounded()),
        windowMinutes: windowMinutes,
        resetsAt: Date(timeIntervalSince1970: resetsAt)
    )
}

private func appServerUsageWindow(from json: [String: Any]) -> UsageWindow? {
    guard let usedPercentValue = doubleValue(json["usedPercent"]) else {
        return nil
    }

    return UsageWindow(
        usedPercent: Int(usedPercentValue.rounded()),
        windowMinutes: intValue(json["windowDurationMins"]) ?? 0,
        resetsAt: doubleValue(json["resetsAt"]).map(Date.init(timeIntervalSince1970:))
    )
}

private func containsResponse(withID id: Int, in output: String) -> Bool {
    output
        .split(whereSeparator: \.isNewline)
        .contains { line in
            guard let data = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return intValue(root["id"]) == id && (root["result"] != nil || root["error"] != nil)
        }
}

private func parseISODate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}

private func clampPercent(_ value: Int) -> Int {
    min(100, max(0, value))
}

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int {
        return int
    }
    if let double = value as? Double {
        return Int(double)
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    return nil
}

private func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double {
        return double
    }
    if let int = value as? Int {
        return Double(int)
    }
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    return nil
}
