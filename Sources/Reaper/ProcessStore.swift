import AppKit
import Foundation
import ServiceManagement

enum ProcessFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case ghosts = "Ghosts"
    var id: String { rawValue }
}

enum ReaperTab: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case worktrees = "Worktrees"
    var id: String { rawValue }
}

@MainActor
final class ProcessStore: ObservableObject {
    @Published private(set) var jobs: [AgentJob] = []
    @Published private(set) var lastScan: Date?
    /// Jobs that survived SIGTERM and can be force-killed.
    @Published private(set) var stubborn: Set<String> = []
    @Published private(set) var terminating: Set<String> = []
    @Published var portsOnly: Bool {
        didSet { UserDefaults.standard.set(portsOnly, forKey: "portsOnly") }
    }
    @Published var filter: ProcessFilter {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: "filter") }
    }
    @Published var tab: ReaperTab {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "tab")
            if tab == .worktrees { refreshWorktrees(ifOlderThan: 10) }
        }
    }

    // Worktrees
    @Published private(set) var worktrees: [Worktree] = []
    @Published private(set) var worktreeStatus: [String: GitStatus] = [:]
    @Published private(set) var sizes: [String: UInt64] = [:]
    @Published private(set) var removing: Set<String> = []
    /// git refused to remove it (usually uncommitted changes); the value is git's message.
    @Published private(set) var removeErrors: [String: String] = [:]
    /// Worktrees showing a confirm button in place of ×.
    @Published private(set) var confirmingRemoval: Set<String> = []

    private let scanner = ProcessScanner()
    private var snapshot = Snapshot()
    private var timer: Timer?
    private var worktreeTimer: Timer?
    private var scanning = false
    private let worktreeScanner = WorktreeScanner()
    private var worktreeScanning = false
    private var lastWorktreeScan: Date?
    private var measuring = false
    /// When each size was measured, and the worktree's last activity at that time.
    private var measured: [String: (at: Date, activity: Date?)] = [:]
    private static let remeasureAfter: TimeInterval = 6 * 3600

    init() {
        portsOnly = UserDefaults.standard.bool(forKey: "portsOnly")
        filter = UserDefaults.standard.string(forKey: "filter").flatMap(ProcessFilter.init) ?? .all
        tab = UserDefaults.standard.string(forKey: "tab").flatMap(ReaperTab.init) ?? .processes
        refresh()
        refreshWorktrees()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        worktreeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWorktrees() }
        }
    }

    /// Already sorted by the scanner: ghosts first, then longest running.
    var visibleJobs: [AgentJob] {
        jobs.filter { (filter == .all || $0.isGhost) && (!portsOnly || !$0.ports.isEmpty) }
    }

    func count(_ filter: ProcessFilter) -> Int {
        switch tab {
        case .processes: jobs.filter { (filter == .all || $0.isGhost) && (!portsOnly || !$0.ports.isEmpty) }.count
        case .worktrees: worktrees.filter { filter == .all || $0.isGhost }.count
        }
    }

    func count(_ tab: ReaperTab) -> Int {
        switch tab {
        case .processes: jobs.count
        case .worktrees: worktrees.count
        }
    }

    /// Keeps the scanner's order within the section: ghosts first, then longest running.
    func jobs(for harness: Harness) -> [AgentJob] {
        visibleJobs.filter { $0.harness == harness }
    }

    var listeningCount: Int { jobs.filter { !$0.ports.isEmpty }.count }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let scanner = scanner
        Task.detached(priority: .utility) {
            let snap = scanner.scan()
            await MainActor.run {
                self.snapshot = snap
                self.jobs = snap.jobs
                self.lastScan = Date()
                let alive = Set(snap.jobs.map(\.id))
                self.stubborn.formIntersection(alive)
                self.terminating.formIntersection(alive)
                self.scanning = false
            }
        }
    }

    // MARK: - Worktrees

    /// Ghosts first, then the longest idle; grouped by agent, with unattributed ones last (nil).
    var visibleWorktrees: [Worktree] {
        worktrees
            .filter { filter == .all || $0.isGhost }
            .map { wt in var wt = wt; wt.status = worktreeStatus[wt.path] ?? wt.status; return wt }
            .sorted {
                if $0.isGhost != $1.isGhost { return $0.isGhost }
                return ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast)
            }
    }

    func worktrees(for harness: Harness?) -> [Worktree] {
        visibleWorktrees.filter { $0.agent == harness }
    }

    /// Total size of the visible worktrees measured so far.
    var visibleWorktreeSize: UInt64 {
        visibleWorktrees.reduce(0) { $0 + (sizes[$1.path] ?? 0) }
    }

    func refreshWorktrees(ifOlderThan age: TimeInterval = 0, forceStatus: Bool = false) {
        if let last = lastWorktreeScan, Date().timeIntervalSince(last) < age { return }
        guard !worktreeScanning else { return }
        worktreeScanning = true
        let scanner = worktreeScanner
        Task.detached(priority: .utility) {
            let list = scanner.scan()
            await MainActor.run {
                self.worktrees = list
                self.lastWorktreeScan = Date()
                let paths = Set(list.map(\.path))
                self.removeErrors = self.removeErrors.filter { paths.contains($0.key) }
                self.confirmingRemoval.formIntersection(paths)
                self.measureSizes()
            }
            // git status is the slow part; show the list first.
            let statuses = scanner.refreshStatuses(list, force: forceStatus)
            await MainActor.run {
                self.worktreeStatus = statuses
                self.worktreeScanning = false
            }
        }
    }

    /// Measures sizes one worktree at a time, ghosts first.
    private func measureSizes() {
        guard !measuring else { return }
        let now = Date()
        let pending = worktrees.filter { wt in
            guard !wt.isPrunable else { return false }
            guard let m = measured[wt.path] else { return true }
            return now.timeIntervalSince(m.at) > Self.remeasureAfter
                || (wt.lastActivity ?? .distantPast) > (m.activity ?? .distantPast)
        }
        .sorted { $0.isGhost && !$1.isGhost }
        guard let next = pending.first else { return }
        measuring = true
        let path = next.path, activity = next.lastActivity
        Task.detached(priority: .background) {
            let size = DiskUsage.size(of: path)
            await MainActor.run {
                self.sizes[path] = size
                self.measured[path] = (Date(), activity)
                self.measuring = false
                self.measureSizes()
            }
        }
    }

    /// First step of every removal: the row swaps × for a confirm button, which reverts after a few seconds.
    func requestRemoval(_ wt: Worktree) {
        let id = wt.id
        removeErrors[id] = nil
        confirmingRemoval.insert(id)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            confirmingRemoval.remove(id)
        }
    }

    /// `git worktree remove`; git itself refuses when there are uncommitted changes, unless forced.
    /// The branch is kept.
    func remove(_ wt: Worktree, force: Bool = false) {
        confirmingRemoval.remove(wt.id)
        removeErrors[wt.id] = nil
        removing.insert(wt.id)
        if wt.isPrunable, !wt.isLocked {
            pruneRecord(wt)
            return
        }
        let args = ["worktree", "remove"] + (force ? ["--force"] : []) + [wt.path]
        let repo = wt.repo, id = wt.id
        Task.detached(priority: .userInitiated) {
            let result = Git.run(args, in: repo)
            await MainActor.run {
                self.removing.remove(id)
                if let result, result.code == 0 {
                    self.worktrees.removeAll { $0.id == id }
                    self.sizes[id] = nil
                    self.measured[id] = nil
                } else {
                    let message = result?.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.removeErrors[id] = (message?.isEmpty == false ? message : nil)
                        ?? "git could not remove this worktree"
                }
                self.refreshWorktrees()
            }
        }
    }

    /// The worktree's `.git` file is gone, so git won't touch it (`git worktree remove` refuses when
    /// leftover folders remain). Do what `git worktree prune` does for this one record, then delete
    /// the leftover folder if it holds no files: macOS's /tmp cleanup leaves empty dirs and symlinks.
    private func pruneRecord(_ wt: Worktree) {
        let id = wt.id, admin = wt.adminDir, path = wt.path
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var failure: String?
            do {
                try fm.removeItem(atPath: admin)
                if fm.fileExists(atPath: path), !WorktreeScanner.containsFiles(path) {
                    try? fm.removeItem(atPath: path)
                }
            } catch {
                failure = "Could not clear git's record at \(admin): \(error.localizedDescription)"
            }
            let message = failure
            await MainActor.run {
                self.removing.remove(id)
                if let message {
                    self.removeErrors[id] = message
                } else {
                    self.worktrees.removeAll { $0.id == id }
                }
                self.refreshWorktrees()
            }
        }
    }

    // MARK: - Killing

    func kill(_ job: AgentJob, force: Bool = false) {
        let pids = subtree(of: job.root.pid)
        signal(pids, force ? SIGKILL : SIGTERM)
        terminating.insert(job.id)
        stubborn.remove(job.id)
        let id = job.id
        let rootPID = job.root.pid
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(force ? 0.5 : 2.5))
            terminating.remove(id)
            if !force, ProcessScanner.isAlive(rootPID) { stubborn.insert(id) }
            refresh()
        }
    }

    func kill(pid: pid_t, force: Bool = false) {
        signal(subtree(of: pid), force ? SIGKILL : SIGTERM)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            refresh()
        }
    }

    /// Root plus every descendant, deepest first so parents don't respawn children.
    private func subtree(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        func visit(_ p: pid_t, depth: Int) {
            guard depth < 256 else { return }
            for c in snapshot.children[p] ?? [] { visit(c, depth: depth + 1) }
            result.append(p)
        }
        visit(pid, depth: 0)
        return result
    }

    private func signal(_ pids: [pid_t], _ sig: Int32) {
        for pid in pids { Darwin.kill(pid, sig) }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}
