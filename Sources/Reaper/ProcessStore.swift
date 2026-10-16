import AppKit
import Foundation
import ServiceManagement

enum ProcessFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case ghosts = "Ghosts"
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

    private let scanner = ProcessScanner()
    private var snapshot = Snapshot()
    private var timer: Timer?
    private var scanning = false

    init() {
        portsOnly = UserDefaults.standard.bool(forKey: "portsOnly")
        filter = UserDefaults.standard.string(forKey: "filter").flatMap(ProcessFilter.init) ?? .all
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Already sorted by the scanner: ghosts first, then longest running.
    var visibleJobs: [AgentJob] {
        jobs.filter { (filter == .all || $0.isGhost) && (!portsOnly || !$0.ports.isEmpty) }
    }

    func count(_ filter: ProcessFilter) -> Int {
        jobs.filter { (filter == .all || $0.isGhost) && (!portsOnly || !$0.ports.isEmpty) }.count
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
