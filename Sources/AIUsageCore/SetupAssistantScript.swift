import Foundation

public enum SetupAssistantScript {
    public static let setupScriptFileName = "setup-accounts.command"
    public static let terminalWrapperFileName = "open-account-setup.command"

    public static func setupScriptCandidates(
        resourceURL: URL?,
        currentDirectory: URL,
        homeDirectory: URL
    ) -> [URL] {
        var candidates: [URL] = []

        if let resourceURL {
            candidates.append(resourceURL.appendingPathComponent(setupScriptFileName))
        }

        candidates.append(currentDirectory.appendingPathComponent("Scripts").appendingPathComponent(setupScriptFileName))
        candidates.append(
            homeDirectory
                .appendingPathComponent("ai-usage-monitor")
                .appendingPathComponent("Scripts")
                .appendingPathComponent(setupScriptFileName)
        )

        return candidates.reduce(into: []) { unique, candidate in
            if !unique.contains(candidate) {
                unique.append(candidate)
            }
        }
    }

    public static func terminalWrapperContents(setupScriptURL: URL) -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail

        export AI_USAGE_MONITOR_FORCE_SETUP=1
        \(shellQuotedPath(setupScriptURL))

        printf '\\nSetup finished. Return to AI Usage Monitor and press refresh if the widget does not update automatically.\\n'
        read -r -p "Press Return to close this window."
        """
    }

    public static func shellQuotedPath(_ url: URL) -> String {
        "'" + url.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
