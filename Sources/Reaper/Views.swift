import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProcessStore
    /// Measured list height; a ScrollView has no ideal height of its own and would collapse otherwise.
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switch store.tab {
                        case .processes:
                            ForEach(Harness.allCases) { harness in
                                let jobs = store.jobs(for: harness)
                                if !jobs.isEmpty {
                                    HarnessSection(harness: harness, jobs: jobs)
                                }
                            }
                        case .worktrees:
                            ForEach(Harness.allCases.map(Optional.some) + [Harness?.none], id: \.self) { harness in
                                let worktrees = store.worktrees(for: harness)
                                if !worktrees.isEmpty {
                                    WorktreeSection(harness: harness, worktrees: worktrees)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    })
                }
                .frame(height: min(max(contentHeight, 60), 560))
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            }
            Divider()
            footer
        }
        .frame(width: 460)
    }

    private var isEmpty: Bool {
        switch store.tab {
        case .processes: store.visibleJobs.isEmpty
        case .worktrees: store.visibleWorktrees.isEmpty
        }
    }

    /// Native controls only: a segmented control for the view, push-on/push-off buttons for filters.
    private var header: some View {
        HStack(spacing: 8) {
            Picker("View", selection: $store.tab) {
                ForEach(ReaperTab.allCases) { t in
                    Text(verbatim: "\(t.rawValue)  \(store.count(t))").monospacedDigit().tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            Toggle(isOn: Binding(get: { store.filter == .ghosts }, set: { store.filter = $0 ? .ghosts : .all })) {
                Text(verbatim: "👻 \(ghostCount)").monospacedDigit()
            }
            .toggleStyle(.button)
            .help(store.tab == .processes
                  ? "Show only ghosts: processes whose agent session has ended"
                  : "Show only ghosts: worktrees whose folder is gone, or that nothing has used for \(Int(WorktreeScanner.staleAfter / 86_400)) days")

            if store.tab == .processes {
                Toggle(isOn: $store.portsOnly) {
                    Label(String(store.listeningCount), systemImage: "antenna.radiowaves.left.and.right")
                        .monospacedDigit()
                }
                .toggleStyle(.button)
                .help("Show only processes listening on a port")
            }

            Button {
                store.refresh()
                store.refreshWorktrees(forceStatus: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var ghostCount: Int {
        switch store.tab {
        case .processes: store.jobs.filter(\.isGhost).count
        case .worktrees: store.worktrees.filter(\.isGhost).count
        }
    }

    private var summary: String {
        switch store.tab {
        case .processes:
            let n = store.jobs.count
            return n == 1 ? "1 process" : "\(n) processes"
        case .worktrees:
            let n = store.worktrees.count
            var text = n == 1 ? "1 worktree" : "\(n) worktrees"
            if store.visibleWorktreeSize > 0 {
                text += " · \(formatSize(store.visibleWorktreeSize))\(store.filter == .ghosts ? " in ghosts" : "")"
            }
            return text
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal").font(.title2).foregroundStyle(.secondary)
            Text(emptyMessage).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var emptyMessage: String {
        if store.tab == .worktrees {
            return store.filter == .ghosts ? "No ghost worktrees" : "No worktrees found"
        }
        return switch (store.filter, store.portsOnly) {
        case (.ghosts, true): "No ghost processes listening on a port"
        case (.ghosts, false): "No ghosts: nothing outlived its agent"
        case (.all, true): "No agent processes listening on a port"
        case (.all, false): "No agent processes running"
        }
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Toggle("Launch at Login", isOn: Binding(
                    get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                Divider()
                Button("Quit Reaper") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(store.tab == .processes ? "Options. Tip: ⌥-click × to force kill." : "Options. Tip: ⌥-click × to force remove.")
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        // ⌘Q also works while the popover is open.
        .background(Button("") { NSApp.terminate(nil) }.keyboardShortcut("q").hidden())
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct HarnessSection: View {
    let harness: Harness
    let jobs: [AgentJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                HarnessIcon(harness: harness, size: 16)
                Text(harness.rawValue).font(.subheadline.weight(.semibold))
                Text(verbatim: "\(jobs.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            VStack(spacing: 2) {
                ForEach(jobs) { JobRow(job: $0) }
            }
        }
    }
}

/// Official app icon when the harness app is installed, SF Symbol otherwise.
struct HarnessIcon: View {
    let harness: Harness
    let size: CGFloat

    var body: some View {
        if let icon = harness.appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: harness.symbol)
                .foregroundStyle(harness.color)
                .frame(width: size, height: size)
        }
    }
}

struct JobRow: View {
    @EnvironmentObject var store: ProcessStore
    let job: AgentJob
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if job.isGhost, store.filter != .ghosts {
                            Text("👻").help("Ghost: its agent session has ended and nothing is managing this process anymore")
                        }
                        Text(job.command)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(job.fullCommand)
                    }
                    HStack(spacing: 4) {
                        if let cwd = job.cwd {
                            Text(shortPath(cwd)).lineLimit(1).truncationMode(.head)
                            Text("·")
                        }
                        Group {
                            Text(verbatim: "pid \(job.root.pid)")
                            Text("·")
                            Text(uptime(since: job.root.started))
                            if let cpu = job.cpu {
                                Text("·")
                                Text(verbatim: "\(formatCPU(cpu)) CPU")
                            }
                            if job.memory > 0 {
                                Text("·")
                                Text(verbatim: formatMemory(job.memory))
                            }
                            if let via = job.via {
                                Text("· via \(via.rawValue)")
                            }
                        }
                        .fixedSize()
                    }
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }

                Spacer(minLength: 4)

                ForEach(job.ports.prefix(3), id: \.self) { port in
                    PortChip(port: port, addresses: job.addresses(for: port), tint: job.harness.color)
                }
                if job.ports.count > 3 {
                    Text(verbatim: "+\(job.ports.count - 3)").font(.caption).foregroundStyle(.secondary)
                }

                killControl
            }

            if expanded { details }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
    }

    @ViewBuilder private var killControl: some View {
        if store.terminating.contains(job.id) {
            ProgressView().controlSize(.small).frame(width: 18)
        } else if store.stubborn.contains(job.id) {
            Button("Force") { store.kill(job, force: true) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .help("Still running after SIGTERM — send SIGKILL")
        } else {
            KillButton {
                store.kill(job, force: NSEvent.modifierFlags.contains(.option))
            }
            .help("Kill process tree (SIGTERM). ⌥-click for SIGKILL.")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.fullCommand)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(.bottom, 2)
            ForEach(job.processes, id: \.pid) { p in
                HStack(spacing: 6) {
                    Text(verbatim: "\(p.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                    Text(ProcessScanner.describe(p, children: [:], procs: [:]).0)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(p.args.joined(separator: " "))
                    Spacer(minLength: 4)
                    ForEach(Array(Set(p.ports.map(\.port))).sorted(), id: \.self) { port in
                        Text(verbatim: ":\(port)").font(.caption.monospacedDigit().weight(.medium))
                    }
                    // After the ports so the columns line up against the kill buttons.
                    Group {
                        Text(verbatim: p.cpu.map(formatCPU) ?? "").frame(width: 44, alignment: .trailing)
                        Text(verbatim: p.memory > 0 ? formatMemory(p.memory) : "").frame(width: 60, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    KillButton(size: .caption) {
                        store.kill(pid: p.pid, force: NSEvent.modifierFlags.contains(.option))
                    }
                    .help("Kill \(p.pid)")
                }
            }
        }
        .padding(.leading, 18)
    }

    @ViewBuilder private var contextMenu: some View {
        ForEach(job.ports, id: \.self) { port in
            Button("Open http://localhost:\(port)") { openPort(port) }
        }
        if !job.ports.isEmpty { Divider() }
        Button("Copy Command") { copy(job.fullCommand) }
        Button("Copy PID") { copy("\(job.root.pid)") }
        if let cwd = job.cwd {
            Button("Reveal Working Directory") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
            }
        }
        Divider()
        Button("Kill (SIGTERM)") { store.kill(job) }
        Button("Force Kill (SIGKILL)") { store.kill(job, force: true) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct PortChip: View {
    let port: UInt16
    let addresses: [String]
    let tint: Color
    @State private var hovering = false

    private var exposed: Bool { addresses.contains { $0 != "localhost" } }

    var body: some View {
        Button { openPort(port) } label: {
            HStack(spacing: 2) {
                if exposed { Image(systemName: "globe").font(.system(size: 8)) }
                Text(verbatim: ":\(port)")
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(.primary)
            .background(Capsule().fill(hovering ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open http://localhost:\(port) — bound to \(addresses.joined(separator: ", "))")
    }
}

struct KillButton: View {
    var size: Font = .body
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(size)
                .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private func openPort(_ port: UInt16) {
    if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
}

func shortPath(_ path: String) -> String {
    let home = ProcessScanner.home
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// Percent of one core, like Activity Monitor: "0.4%", "103.2%".
func formatCPU(_ cpu: Double) -> String {
    String(format: "%.1f%%", cpu)
}

func formatMemory(_ bytes: UInt64) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: .memory))
}

private func uptime(since date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    switch s {
    case ..<60: return "\(s)s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h \(s % 3600 / 60)m"
    default: return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

/// Disk size: "6.0 GB".
func formatSize(_ bytes: UInt64) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: .file))
}

/// Coarse age: "45s", "12m", "5h", "3d", "6w".
func relativeAge(_ date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    switch s {
    case ..<60: return "\(s)s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h"
    case ..<(14 * 86400): return "\(s / 86400)d"
    default: return "\(s / (7 * 86400))w"
    }
}
