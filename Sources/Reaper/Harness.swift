import AppKit
import SwiftUI

/// A coding-agent harness that can spawn processes.
enum Harness: String, CaseIterable, Identifiable, Sendable {
    case claudeCode = "Claude Code"
    case cursor = "Cursor"
    case codex = "Codex"
    case opencode = "OpenCode"
    case t3 = "T3 Code"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .cursor: "cursorarrow.rays"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .opencode: "curlybraces"
        case .t3: "t.square"
        }
    }

    /// Bundle identifiers of the harness's desktop app, most likely first.
    var bundleIDs: [String] {
        switch self {
        case .claudeCode: ["com.anthropic.claudefordesktop"]
        case .cursor: ["com.todesktop.230313mzl4w4u92", "com.anysphere.cursor"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .opencode: ["ai.opencode.desktop"]
        case .t3: ["com.t3tools.t3code"]
        }
    }

    /// The official app icon, taken from the installed app (nil if not installed).
    @MainActor var appIcon: NSImage? { HarnessIcons.icon(for: self) }

    var color: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .cursor: Color(red: 0.45, green: 0.55, blue: 0.95)
        case .codex: Color(red: 0.20, green: 0.70, blue: 0.55)
        case .opencode: Color(red: 0.90, green: 0.70, blue: 0.20)
        case .t3: Color(red: 0.70, green: 0.45, blue: 0.90)
        }
    }
}

/// Decides whether a process *is* a harness (so it's hidden) and which harness
/// a process belongs to when its parent chain was broken (via env markers).
enum HarnessMatcher {
    /// Only these environment keys are ever retained from a process.
    static let markerKeys: Set<String> = [
        "AI_AGENT", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TERM_PROGRAM",
        "CODEX_SHELL", "CODEX_SANDBOX", "CODEX_THREAD_ID", "CODEX_CI",
        "OPENCODE", "CURSOR_AGENT", "CURSOR_TRACE_ID",
        "XPC_SERVICE_NAME", "__CFBundleIdentifier",
    ]

    /// The harness this executable is part of (the agent itself or one of its helpers).
    static func harness(executable path: String, args: [String]) -> Harness? {
        let base = (path as NSString).lastPathComponent.lowercased()
        func has(_ s: String) -> Bool { path.contains(s) }

        if has("/Claude.app/") || has("/Application Support/Claude/") || has("/.local/share/claude/")
            || has("/.claude/") || base == "claude" { return .claudeCode }
        if has("/Cursor.app/") || has("/Application Support/Cursor/") || has("/.cursor/")
            || base == "cursor-agent" || base == "cursorsandbox" { return .cursor }
        if has("/Codex.app/") || has("/ChatGPT.app/") || has("/.codex/") || has("/com.openai.codex/")
            || base == "codex" || base.hasPrefix("codex-") { return .codex }
        if has("/OpenCode.app/") || has("/.opencode/") || base == "opencode" { return .opencode }
        if has("/T3 Code") || base == "t3code" { return .t3 }

        // Script-based CLIs: `node …/@anthropic-ai/claude-code/cli.js` and friends.
        if ["node", "bun", "deno"].contains(base) {
            for arg in args.dropFirst().prefix(4) {
                if arg.contains("@anthropic-ai/claude-code") { return .claudeCode }
                if arg.contains("@openai/codex") { return .codex }
                if arg.contains("opencode-ai") || arg.contains("/opencode/bin") { return .opencode }
                if arg.contains("/node_modules/t3/") || arg.contains("t3code") { return .t3 }
                if arg.contains("cursor-agent") { return .cursor }
            }
        }
        return nil
    }

    /// Fallback attribution for orphans (reparented to launchd) using inherited env markers.
    /// Returns the agent and, if different, the app hosting it.
    static func harness(env: [String: String]) -> (Harness, via: Harness?)? {
        var agent: Harness?
        if let value = env["AI_AGENT"]?.lowercased() { agent = fromName(value) }
        if agent == nil {
            if env["CLAUDECODE"] != nil || env["CLAUDE_CODE_ENTRYPOINT"] != nil
                || env["TERM_PROGRAM"] == "claude-desktop" {
                agent = .claudeCode
            } else if env["CODEX_SHELL"] != nil || env["CODEX_SANDBOX"] != nil
                        || env["CODEX_THREAD_ID"] != nil || env["CODEX_CI"] != nil {
                agent = .codex
            } else if env["OPENCODE"] != nil {
                agent = .opencode
            } else if env["CURSOR_AGENT"] != nil || env["CURSOR_TRACE_ID"] != nil {
                agent = .cursor
            }
        }

        let bundle = (env["XPC_SERVICE_NAME"] ?? "") + " " + (env["__CFBundleIdentifier"] ?? "")
        let host = fromBundleID(bundle.lowercased())

        switch (agent, host) {
        case let (a?, h?) where a != h: return (a, h)
        case let (a?, _): return (a, nil)
        case let (nil, h?): return (h, nil)
        default: return nil
        }
    }

    private static func fromName(_ s: String) -> Harness? {
        if s.contains("claude") { return .claudeCode }
        if s.contains("cursor") { return .cursor }
        if s.contains("codex") { return .codex }
        if s.contains("opencode") { return .opencode }
        if s.contains("t3") { return .t3 }
        return nil
    }

    private static func fromBundleID(_ s: String) -> Harness? {
        if s.contains("com.anthropic.claude") { return .claudeCode }
        if s.contains("com.todesktop.230313mzl4w4u92") || s.contains("com.anysphere.cursor") { return .cursor }
        if s.contains("com.openai.codex") || s.contains("com.openai.chat") { return .codex }
        if s.contains("opencode") { return .opencode }
        if s.contains("com.t3tools.t3code") { return .t3 }
        return nil
    }

    /// Editor plumbing that isn't something an agent "started" (language servers, updaters, etc.).
    /// Descendants of noise are noise too.
    static func isNoise(path: String, args: [String]) -> Bool {
        if path.contains("/Sparkle") || path.contains("/Updater.app/") { return true }
        return args.contains { arg in
            let a = arg.lowercased()
            return a == "--lsp" || a.contains("language-server") || a.contains("languageserver")
                || a.contains("langserver") || a.hasSuffix("tsserver.js") || a.contains("typingsinstaller")
        }
    }
}

extension HarnessMatcher {
    /// Harness processes whose children are editor extensions, not agent work.
    static func isEditorHost(args: [String]) -> Bool {
        args.first?.contains("extension-host") == true
    }
}

@MainActor
enum HarnessIcons {
    private static var cache: [Harness: NSImage?] = [:]

    static func icon(for harness: Harness) -> NSImage? {
        if let cached = cache[harness] { return cached }
        let url = harness.bundleIDs.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[harness] = image
        return image
    }
}
