import Darwin
import Foundation

/// A linked git worktree (the main checkout of a repo is never listed).
struct Worktree: Identifiable, Sendable {
    var id: String { path }
    let path: String
    /// The main checkout, or the git dir of a bare repo.
    let repo: String
    /// `<common git dir>/worktrees/<name>`.
    let adminDir: String
    let branch: String?
    /// Short commit hash when HEAD is detached.
    let detachedAt: String?
    /// The folder is gone but git still records it.
    let isPrunable: Bool
    let isLocked: Bool
    /// The agent that last had a session here, or the one that created it.
    let agent: Harness?
    /// The tool that created it, from its location ("Trevize", "Conductor", "Codex"…).
    let creator: String?
    let lastActivity: Date?
    /// Processes whose working directory is inside it.
    let processes: [WorktreeProcess]
    var status: GitStatus?
    let isGhost: Bool

    var name: String { branch ?? (path as NSString).lastPathComponent }
    var repoName: String { (repo as NSString).lastPathComponent }
    var inUse: Bool { !processes.isEmpty }

    /// The creator, when it adds something beyond the agent's name.
    var via: String? { creator == agent?.rawValue ? nil : creator }
}

struct WorktreeProcess: Sendable, Hashable {
    let pid: pid_t
    let name: String
}

struct GitStatus: Sendable {
    /// Modified, staged and untracked files.
    let changed: Int
    /// Commits on HEAD that are on no remote and no other local branch.
    let unmerged: Int
    let checked: Date
}

final class WorktreeScanner: @unchecked Sendable {
    /// Idle for this long (and nothing running in it) makes a worktree a ghost.
    static let staleAfter: TimeInterval = 7 * 86_400
    private static let statusTTL: TimeInterval = 5 * 60
    private static let reposKey = "knownRepos"

    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    private let myUID = getuid()
    /// Common git dirs (`…/.git`) of every repo seen so far; remembered across launches.
    private var knownRepos: Set<String>
    private var claudeProjectCwd: [String: String] = [:]
    private var codexSessionCwd: [String: String] = [:]
    private var statusCache: [String: GitStatus] = [:]
    private let lock = NSLock()
    private let statusLock = NSLock()

    init() {
        knownRepos = Set(UserDefaults.standard.stringArray(forKey: Self.reposKey) ?? [])
    }

    func scan() -> [Worktree] {
        lock.lock(); defer { lock.unlock() }
        let sessions = sessionActivity()
        let procs = processCwds()

        // 1. Repo discovery: anywhere an agent worked or a process runs, plus known worktree folders.
        var candidates = Set(sessions.map(\.cwd))
        candidates.formUnion(procs.map(\.cwd))
        candidates.formUnion(knownWorktreeFolders())
        var commonDirs = Set<String>()
        var checkedDirs: [String: String?] = [:]
        for path in candidates where path != "/" {
            if let dir = commonGitDir(containing: path, cache: &checkedDirs) { commonDirs.insert(dir) }
        }
        knownRepos.formUnion(commonDirs)
        knownRepos = knownRepos.filter { fm.fileExists(atPath: $0) }
        UserDefaults.standard.set(Array(knownRepos).sorted(), forKey: Self.reposKey)

        // 2. Each repo's worktrees, read from its admin dirs the way `git worktree list` does.
        let now = Date()
        var result: [Worktree] = []
        for common in knownRepos {
            let adminRoot = (common as NSString).appendingPathComponent("worktrees")
            guard let names = try? fm.contentsOfDirectory(atPath: adminRoot) else { continue }
            let repo = (common as NSString).lastPathComponent == ".git"
                ? (common as NSString).deletingLastPathComponent : common
            for name in names {
                let admin = (adminRoot as NSString).appendingPathComponent(name)
                guard let wt = worktree(admin: admin, repo: repo, sessions: sessions, procs: procs, now: now)
                else { continue }
                result.append(wt)
            }
        }
        return result
    }

    private func worktree(admin: String, repo: String, sessions: [Session], procs: [ProcCwd], now: Date) -> Worktree? {
        guard let gitdirRaw = read(admin + "/gitdir")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !gitdirRaw.isEmpty else { return nil }
        let gitFile = resolve(gitdirRaw, relativeTo: admin)
        let path = (gitFile as NSString).deletingLastPathComponent
        let isPrunable = !fm.fileExists(atPath: gitFile)
        let isLocked = fm.fileExists(atPath: admin + "/locked")

        var branch: String?
        var detached: String?
        if let head = read(admin + "/HEAD")?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if head.hasPrefix("ref: ") {
                let ref = head.dropFirst(5)
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : String(ref)
            } else {
                detached = String(head.prefix(7))
            }
        }

        func inside(_ p: String) -> Bool { p == path || p.hasPrefix(path + "/") }
        let mine = sessions.filter { inside($0.cwd) }
        let latest = mine.max { $0.date < $1.date }
        let gitActivity = ["HEAD", "index", "logs/HEAD"].compactMap { modified(admin + "/" + $0) }.max()
        let lastActivity = [latest?.date, gitActivity].compactMap { $0 }.max()

        let creator = Self.creator(of: path, home: home)
        let agent = latest?.harness ?? creator?.harness
        let processes = isPrunable ? [] : procs.filter { inside($0.cwd) }.map { WorktreeProcess(pid: $0.pid, name: $0.name) }

        statusLock.lock()
        let status = isPrunable ? nil : statusCache[path]
        statusLock.unlock()

        let stale = (lastActivity ?? .distantPast) < now.addingTimeInterval(-Self.staleAfter)
        let isGhost = !isLocked && (isPrunable || (processes.isEmpty && stale))

        return Worktree(path: path, repo: repo, adminDir: admin, branch: branch, detachedAt: detached,
                        isPrunable: isPrunable, isLocked: isLocked, agent: agent, creator: creator?.name,
                        lastActivity: lastActivity, processes: processes, status: status, isGhost: isGhost)
    }

    /// Which tool made a worktree, judging by where it lives.
    static func creator(of path: String, home: String) -> (name: String, harness: Harness?)? {
        if path.contains("/.claude/worktrees/") { return (Harness.claudeCode.rawValue, .claudeCode) }
        let rules: [(String, String, Harness?)] = [
            ("/.codex/worktrees/", Harness.codex.rawValue, .codex),
            ("/.t3/worktrees/", Harness.t3.rawValue, .t3),
            ("/.cursor/worktrees/", Harness.cursor.rawValue, .cursor),
            ("/.trevize/worktrees/", "Trevize", nil),
            ("/conductor/workspaces/", "Conductor", nil),
        ]
        for (folder, name, harness) in rules where path.hasPrefix(home + folder) { return (name, harness) }
        return nil
    }

    /// Whether anything other than directories and symlinks lives under `path`.
    static func containsFiles(_ path: String) -> Bool {
        guard let e = FileManager.default.enumerator(atPath: path) else { return true }
        while e.nextObject() != nil {
            let type = e.fileAttributes?[.type] as? FileAttributeType
            if type != .typeDirectory && type != .typeSymbolicLink { return true }
        }
        return false
    }

    // MARK: - Repo discovery

    /// Worktree folders tools are known to use: `<root>/<repo>/<worktree>` or `<root>/<id>/<repo>`.
    private func knownWorktreeFolders() -> [String] {
        let roots = [".codex/worktrees", ".t3/worktrees", ".cursor/worktrees", ".trevize/worktrees", "conductor/workspaces"]
        var result: [String] = []
        for root in roots {
            let base = (home as NSString).appendingPathComponent(root)
            for a in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where !a.hasPrefix(".") {
                let level1 = (base as NSString).appendingPathComponent(a)
                for b in (try? fm.contentsOfDirectory(atPath: level1)) ?? [] where !b.hasPrefix(".") {
                    result.append((level1 as NSString).appendingPathComponent(b))
                }
            }
        }
        return result
    }

    /// The common git dir of the repo containing `path`, following a worktree's `.git` file back to it.
    private func commonGitDir(containing path: String, cache: inout [String: String?]) -> String? {
        var dir = path
        var visited: [String] = []
        while dir != "/" && !dir.isEmpty {
            if let hit = cache[dir] {
                for v in visited { cache[v] = .some(hit) }
                return hit
            }
            visited.append(dir)
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                var found: String?
                if isDir.boolValue {
                    found = dotGit
                } else if let text = read(dotGit), text.hasPrefix("gitdir: ") {
                    let gitdir = resolve(text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: dir)
                    if let common = read(gitdir + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        found = resolve(common, relativeTo: gitdir)
                    } else {
                        found = gitdir
                    }
                }
                for v in visited { cache[v] = .some(found) }
                return found
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        for v in visited { cache[v] = .some(nil) }
        return nil
    }

    // MARK: - Agent sessions

    struct Session { let cwd: String; let harness: Harness; let date: Date }

    /// Where agents ran sessions, from their own logs. Only the recorded `cwd` is read.
    private func sessionActivity() -> [Session] {
        var result: [Session] = []

        // Claude Code: ~/.claude/projects/<encoded cwd>/<session>.jsonl
        let projects = (home as NSString).appendingPathComponent(".claude/projects")
        for dirName in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let dir = (projects as NSString).appendingPathComponent(dirName)
            let logs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }
                .compactMap { name -> (String, Date)? in
                    let p = (dir as NSString).appendingPathComponent(name)
                    return modified(p).map { (p, $0) }
                }
                .sorted { $0.1 > $1.1 }
            guard let newest = logs.first else { continue }
            if claudeProjectCwd[dir] == nil {
                for (log, _) in logs.prefix(3) {
                    if let cwd = Self.firstCwd(in: log, limit: 256 * 1024) { claudeProjectCwd[dir] = cwd; break }
                }
            }
            if let cwd = claudeProjectCwd[dir] { result.append(Session(cwd: cwd, harness: .claudeCode, date: newest.1)) }
        }

        // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl (compressed archives are skipped).
        let codex = (home as NSString).appendingPathComponent(".codex/sessions")
        if let e = fm.enumerator(atPath: codex) {
            var seen = Set<String>()
            while let rel = e.nextObject() as? String {
                guard rel.hasSuffix(".jsonl") else { continue }
                let p = (codex as NSString).appendingPathComponent(rel)
                seen.insert(p)
                if codexSessionCwd[p] == nil, let cwd = Self.firstCwd(in: p, limit: 64 * 1024) { codexSessionCwd[p] = cwd }
                if let cwd = codexSessionCwd[p], let date = modified(p) {
                    result.append(Session(cwd: cwd, harness: .codex, date: date))
                }
            }
            codexSessionCwd = codexSessionCwd.filter { seen.contains($0.key) }
        }
        return result
    }

    /// The first `"cwd":"…"` value in the head of a JSONL log.
    static func firstCwd(in file: String, limit: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "\"cwd\":\"") else { return nil }
        var value = ""
        var escaped = false
        for ch in text[key.upperBound...] {
            if escaped { value.append(ch); escaped = false; continue }
            if ch == "\\" { value.append(ch); escaped = true; continue }
            if ch == "\"" {
                // Let JSON undo any escaping.
                let decoded = try? JSONSerialization.jsonObject(with: Data("\"\(value)\"".utf8), options: .fragmentsAllowed)
                return decoded as? String
            }
            value.append(ch)
        }
        return nil
    }

    // MARK: - Processes

    struct ProcCwd { let pid: pid_t; let name: String; let cwd: String }

    private func processCwds() -> [ProcCwd] {
        let me = getpid()
        return ProcessScanner.allPids().compactMap { pid in
            guard pid != me, let bsd = ProcessScanner.bsdInfo(pid), bsd.pbi_uid == myUID,
                  let cwd = ProcessScanner.cwd(pid), cwd != "/" else { return nil }
            let name = ProcessScanner.path(pid).map { ($0 as NSString).lastPathComponent } ?? "?"
            return ProcCwd(pid: pid, name: name, cwd: cwd)
        }
    }

    // MARK: - git

    /// Runs `git status` for worktrees whose cached status is older than the TTL (or all with `force`).
    /// Slow (a git call or two per worktree), so it runs after `scan()` has listed them.
    func refreshStatuses(_ worktrees: [Worktree], force: Bool = false) -> [String: GitStatus] {
        let now = Date()
        var result: [String: GitStatus] = [:]
        for wt in worktrees where !wt.isPrunable {
            statusLock.lock()
            let cached = statusCache[wt.path]
            statusLock.unlock()
            if !force, let cached, now.timeIntervalSince(cached.checked) < Self.statusTTL {
                result[wt.path] = cached
            } else if let fresh = gitStatus(path: wt.path, branch: wt.branch, now: now) {
                statusLock.lock()
                statusCache[wt.path] = fresh
                statusLock.unlock()
                result[wt.path] = fresh
            }
        }
        return result
    }

    private func gitStatus(path: String, branch: String?, now: Date) -> GitStatus? {
        guard let status = Git.run(["status", "--porcelain", "--untracked-files=normal"], in: path),
              status.code == 0 else { return nil }
        let changed = status.output.split(whereSeparator: \.isNewline).count
        var args = ["rev-list", "--count", "HEAD", "--not"]
        if let branch { args.append("--exclude=\(branch)") }
        args += ["--branches", "--remotes"]
        let unmerged = Git.run(args, in: path).flatMap { $0.code == 0 ? Int($0.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil } ?? 0
        return GitStatus(changed: changed, unmerged: unmerged, checked: now)
    }

    // MARK: - Files

    private func read(_ path: String) -> String? {
        guard let data = fm.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func modified(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    private func resolve(_ path: String, relativeTo base: String) -> String {
        let full = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (full as NSString).standardizingPath
    }
}

enum Git {
    /// A real git, never the `/usr/bin/git` shim when it would prompt to install developer tools.
    static let executable: String? = {
        let fm = FileManager.default
        let direct = ["/opt/homebrew/bin/git", "/usr/local/bin/git",
                      "/Library/Developer/CommandLineTools/usr/bin/git",
                      "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        if let found = direct.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        return nil
    }()

    static var isAvailable: Bool { executable != nil }

    /// Runs git without taking optional locks, so it never blocks an agent's own git use.
    static func run(_ args: [String], in dir: String) -> (code: Int32, output: String, error: String)? {
        guard let executable else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}

enum DiskUsage {
    /// Allocated size of everything under `path`, measured like `du`: no symlinks followed,
    /// hard-linked files counted once.
    static func size(of path: String) -> UInt64 {
        var total: UInt64 = 0
        var seen = Set<HardLink>()
        path.withCString { cPath in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(paths[0]) }
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(fts) }
            while let entry = fts_read(fts) {
                let info = Int32(entry.pointee.fts_info)
                guard info == FTS_F || info == FTS_D || info == FTS_SL || info == FTS_DEFAULT,
                      let st = entry.pointee.fts_statp?.pointee else { continue }
                if info == FTS_F, st.st_nlink > 1, !seen.insert(HardLink(dev: st.st_dev, ino: st.st_ino)).inserted { continue }
                total += UInt64(max(st.st_blocks, 0)) * 512
            }
        }
        return total
    }

    private struct HardLink: Hashable { let dev: dev_t; let ino: ino_t }
}
