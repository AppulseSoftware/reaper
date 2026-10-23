import AppKit
import Combine
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            dump()
        } else {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                let delegate = AppDelegate()
                app.delegate = delegate
                app.setActivationPolicy(.accessory)
                app.run()
            }
        }
    }

    /// Print the current scan to stdout (handy for debugging detection).
    private static func dump() {
        // A first scan gives the CPU baseline.
        let scanner = ProcessScanner()
        _ = scanner.scan()
        Thread.sleep(forTimeInterval: 1)
        let start = Date()
        let snap = scanner.scan()
        for job in snap.jobs {
            let via = job.via.map { " via \($0.rawValue)" } ?? ""
            let ports = job.ports.map { ":\($0)" }.joined(separator: " ")
            let ghost = job.isGhost ? " GHOST" : ""
            print("[\(job.harness.rawValue)\(via)\(ghost)] pid \(job.root.pid) \(ports.isEmpty ? "-" : ports)  \(job.command)")
            print("    cwd: \(job.cwd ?? "?")  procs: \(job.processes.count)  \(job.cpu.map(formatCPU) ?? "–") CPU  \(formatMemory(job.memory))")
        }
        print(String(format: "%d jobs, scan took %.0f ms", snap.jobs.count, Date().timeIntervalSince(start) * 1000))
    }
}

/// Status item + popover. Unlike MenuBarExtra's window, the popover follows the
/// content's preferred size, so it grows and shrinks with the list.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ProcessStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }

        let host = NSHostingController(rootView: ContentView().environmentObject(store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false

        // @Published emits before the change lands; hop to the next runloop turn to read the new value.
        store.$jobs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
        updateButton()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let count = store.listeningCount
        button.image = count > 0 ? MenuBarIcon.active : MenuBarIcon.idle
        button.title = count > 0 ? " \(count)" : ""
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }
}
