import AppKit
import SwiftUI

struct WorktreeSection: View {
    /// nil for worktrees no agent session can be traced to.
    let harness: Harness?
    let worktrees: [Worktree]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let harness {
                    HarnessIcon(harness: harness, size: 16)
                } else {
                    Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 16, height: 16)
                }
                Text(harness?.rawValue ?? "Other").font(.subheadline.weight(.semibold))
                Text(verbatim: "\(worktrees.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .help(harness == nil ? "No agent session ran in these worktrees; likely made by hand or by a script" : "")
            VStack(spacing: 2) {
                ForEach(worktrees) { WorktreeRow(worktree: $0) }
            }
        }
    }
}

struct WorktreeRow: View {
    @EnvironmentObject var store: ProcessStore
    let worktree: Worktree
    @State private var hovering = false
    @State private var expanded = false

    private var size: UInt64? { store.sizes[worktree.path] }

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
                        if worktree.isGhost, store.filter != .ghosts {
                            Text("👻").help(worktree.isPrunable
                                ? "Ghost: the folder is gone, git only still records it"
                                : "Ghost: nothing has used this worktree for \(Int(WorktreeScanner.staleAfter / 86_400)) days")
                        }
                        Text(worktree.name)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(worktree.path)
                        badges
                    }
                    HStack(spacing: 4) {
                        Text(worktree.repoName)
                        Text("·")
                        activity
                        if let via = worktree.via {
                            Text("· via \(via)")
                        }
                    }
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }

                Spacer(minLength: 4)

                sizeLabel
                removeControl
            }

            if expanded { details }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
    }

    @ViewBuilder private var badges: some View {
        if worktree.isPrunable {
            Badge(text: "missing", tint: .secondary)
                .help("The worktree's files are gone; git only still records it. Clean Up clears that record.")
        }
        if worktree.isLocked {
            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                .help("Locked with git worktree lock")
        }
        if let status = worktree.status {
            if status.changed > 0 {
                Badge(text: "\(status.changed) changed", tint: .orange)
                    .help("Uncommitted or untracked files. Deleting the worktree discards them.")
            }
            if status.unmerged > 0 {
                Badge(text: "\(status.unmerged) unmerged", tint: .orange)
                    .help("Commits that are on no remote and no other branch. Deleting the worktree keeps the branch, so they stay in the repo.")
            }
        }
    }

    @ViewBuilder private var activity: some View {
        if worktree.inUse {
            Text("in use").foregroundStyle(.green)
        } else if let date = worktree.lastActivity {
            Text(verbatim: "active \(relativeAge(date)) ago")
        } else {
            Text("no activity")
        }
    }

    @ViewBuilder private var sizeLabel: some View {
        if let size {
            Text(verbatim: formatSize(size))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// × first; then a confirm button: blue Clean Up when only git's record is left, red Delete when
    /// a folder goes. If git refuses (uncommitted changes), red Delete Anyway.
    @ViewBuilder private var removeControl: some View {
        if !Git.isAvailable {
            EmptyView()
        } else if store.removing.contains(worktree.id) {
            ProgressView().controlSize(.small).frame(width: 18)
        } else if store.removeErrors[worktree.id] != nil {
            Button("Delete Anyway", role: .destructive) { store.remove(worktree, force: true) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .help((store.removeErrors[worktree.id] ?? "") + "\n\nDelete Anyway discards those changes. The branch is kept.")
        } else if store.confirmingRemoval.contains(worktree.id) {
            if worktree.isPrunable {
                Button("Clean Up") { store.remove(worktree) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Clear git's record of this worktree. Its files are already gone; the branch is kept.")
            } else {
                Button("Delete", role: .destructive) { store.remove(worktree) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .help(deleteHelp)
            }
        } else {
            KillButton {
                if NSEvent.modifierFlags.contains(.option) {
                    store.remove(worktree, force: true)
                } else {
                    store.requestRemoval(worktree)
                }
            }
            .help(worktree.isPrunable
                  ? "Clean up git's record of this worktree"
                  : "Delete this worktree's folder; the branch is kept. ⌥-click to delete right away, discarding changes.")
        }
    }

    private var deleteHelp: String {
        var text = "Delete \(shortPath(worktree.path)) with git worktree remove. The branch is kept."
        if worktree.inUse {
            text += "\n\n\(worktree.processes.count) running processes use this folder."
        }
        return text
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(worktree.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            if let sha = worktree.detachedAt {
                Text(verbatim: "Detached HEAD at \(sha)").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.removeErrors[worktree.id] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4)
            }
            ForEach(worktree.processes, id: \.self) { p in
                HStack(spacing: 6) {
                    Text(verbatim: "\(p.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                    Text(p.name).font(.system(.caption, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 4)
                    KillButton(size: .caption) {
                        store.kill(pid: p.pid, force: NSEvent.modifierFlags.contains(.option))
                    }
                    .help("Kill \(p.pid)")
                }
            }
        }
        .padding(.leading, 18)
        .padding(.top, 2)
    }

    @ViewBuilder private var contextMenu: some View {
        if !worktree.isPrunable {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
            }
            Button("Open in Terminal") {
                NSWorkspace.shared.open([URL(fileURLWithPath: worktree.path)],
                                        withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            Divider()
        }
        Button("Copy Path") { copy(worktree.path) }
        if let branch = worktree.branch {
            Button("Copy Branch Name") { copy(branch) }
        }
        if Git.isAvailable {
            Divider()
            if worktree.isPrunable {
                Button("Clean Up") { store.remove(worktree) }
            } else {
                Button("Delete Worktree…") { store.requestRemoval(worktree) }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(.primary)
            .background(Capsule().fill(tint.opacity(0.2)))
            .fixedSize()
    }
}
