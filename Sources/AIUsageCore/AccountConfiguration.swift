import Foundation

public extension AnalyticsProvider {
    static func normalized(from rawProvider: String) -> AnalyticsProvider? {
        let normalized = rawProvider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]",
                with: "",
                options: .regularExpression
            )

        switch normalized {
        case "codex", "codexsubscription":
            return .codex
        case "claude", "claudecode", "claudesubscription", "claudecodesubscription":
            return .claudeCode
        case "openai", "openaiapi", "chatgpt", "chatgptapi":
            return .openAIAPI
        case "anthropic", "anthropicapi", "claudeapi":
            return .anthropicAPI
        case "deepseek", "deepseekapi":
            return .deepseekAPI
        case "gemini", "geminiapi", "googleai", "google", "googleaiapi", "geminibeta":
            return .googleAIAPI
        case "glm", "glmapi":
            return .glmAPI
        default:
            return nil
        }
    }
}

public struct AnalyticsAccountsConfigurationFile: Codable, Equatable {
    public let accounts: [AnalyticsAccountConfiguration]

    public init(accounts: [AnalyticsAccountConfiguration]) {
        self.accounts = accounts
    }

    public var enabledAccounts: [AnalyticsAccountConfiguration] {
        accounts.filter(\.isEnabled)
    }

    public static let exampleJSON = """
    {
      "accounts": [
        {
          "id": "codex-subscription",
          "provider": "codex subscription",
          "label": "Codex",
          "enabled": false
        },
        {
          "id": "claude-code-local",
          "provider": "Claude subscription",
          "label": "Claude Code",
          "enabled": false
        },
        {
          "id": "openai-main",
          "provider": "OpenAI API",
          "label": "OpenAI API",
          "platformCredential": "<OPENAI_ADMIN_ORG_KEY>",
          "usageEndpoint": "https://api.openai.com/v1/organization/usage/completions",
          "costEndpoint": "https://api.openai.com/v1/organization/costs",
          "enabled": false
        },
        {
          "id": "anthropic-main",
          "provider": "Anthropic API",
          "label": "Anthropic API",
          "platformCredential": "<ANTHROPIC_ADMIN_USAGE_KEY>",
          "usageEndpoint": "https://api.anthropic.com/v1/usage",
          "enabled": false
        },
        {
          "id": "gemini-main",
          "provider": "Gemini API",
          "label": "Gemini API",
          "platformCredential": "<GEMINI_USAGE_CREDENTIAL>",
          "usageEndpoint": "https://generativelanguage.googleapis.com/v1beta/usage",
          "balanceEndpoint": "https://generativelanguage.googleapis.com/v1beta/billing",
          "enabled": false
        },
        {
          "id": "deepseek-main",
          "provider": "DeepSeek API",
          "label": "DeepSeek API",
          "platformCredential": "<DEEPSEEK_ACCOUNT_CREDENTIAL>",
          "balanceEndpoint": "https://api.deepseek.com/user/balance",
          "enabled": false
        },
        {
          "id": "glm-main",
          "provider": "GLM API",
          "label": "GLM API",
          "platformCredential": "<GLM_USAGE_CREDENTIAL>",
          "usageEndpoint": "https://open.bigmodel.cn/api/paas/v4/usage",
          "costEndpoint": "https://open.bigmodel.cn/api/paas/v4/usage",
          "enabled": false
        }
      ]
    }
    """
}

public struct AnalyticsAccountConfiguration: Codable, Equatable {
    public let id: String
    public let provider: String
    public let label: String?
    public let platformCredential: String?
    public let apiKey: String?
    public let usageEndpoint: String?
    public let costEndpoint: String?
    public let balanceEndpoint: String?
    public let monthlyBudgetUSD: Double?
    public let enabled: Bool?

    public init(
        id: String,
        provider: String,
        label: String? = nil,
        platformCredential: String? = nil,
        apiKey: String? = nil,
        usageEndpoint: String? = nil,
        costEndpoint: String? = nil,
        balanceEndpoint: String? = nil,
        monthlyBudgetUSD: Double? = nil,
        enabled: Bool? = true
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.platformCredential = platformCredential
        self.apiKey = apiKey
        self.usageEndpoint = usageEndpoint
        self.costEndpoint = costEndpoint
        self.balanceEndpoint = balanceEndpoint
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.enabled = enabled
    }

    public var isEnabled: Bool {
        enabled ?? true
    }

    public var providerKind: AnalyticsProvider? {
        AnalyticsProvider.normalized(from: provider)
    }

    public var effectivePlatformCredential: String? {
        let credential = (platformCredential ?? apiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let credential,
              !credential.isEmpty,
              !(credential.hasPrefix("<") && credential.hasSuffix(">")) else {
            return nil
        }

        return credential
    }
}
