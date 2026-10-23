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
            if store.visibleJobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Harness.allCases) { harness in
                            let jobs = store.jobs(for: harness)
                            if !jobs.isEmpty {
                                HarnessSection(harness: harness, jobs: jobs)
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

    private var header: some View {
        HStack {
            Picker("Show", selection: $store.filter) {
                ForEach(ProcessFilter.allCases) { f in
                    Text(verbatim: "\(f == .ghosts ? "👻 " : "")\(f.rawValue)  \(store.count(f))").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Ghosts are processes whose agent session has ended")
            Spacer()
            Toggle("Listening only", isOn: $store.portsOnly)
                .toggleStyle(.checkbox)
                .font(.caption)
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh now")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
        switch (store.filter, store.portsOnly) {
        case (.ghosts, true): "No ghost processes listening on a port"
        case (.ghosts, false): "No ghosts: nothing outlived its agent"
        case (.all, true): "No agent processes listening on a port"
        case (.all, false): "No agent processes running"
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                .toggleStyle(.checkbox)
            Spacer()
            Text("⌥-click × to force kill").foregroundStyle(.tertiary)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 7)
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
                        if job.isGhost {
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
                        Text(verbatim: ":\(port)").font(.caption.monospacedDigit()).foregroundStyle(job.harness.color)
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
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(hovering ? 0.28 : 0.15)))
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

private func shortPath(_ path: String) -> String {
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
