import Darwin
import Foundation

struct ListenPort: Hashable, Sendable {
    let port: UInt16
    /// "localhost", "*" (all interfaces) or a concrete address.
    let address: String
}

struct ProcInfo: Sendable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let path: String
    let args: [String]
    let markerEnv: [String: String]
    let started: Date
    var ports: [ListenPort] = []
    /// Physical memory footprint in bytes, the figure Activity Monitor shows as Memory.
    var memory: UInt64 = 0
    /// Percent of one core since the previous scan (can exceed 100); nil on the first sighting.
    var cpu: Double?

    var executableName: String {
        let first = args.first.map { ($0 as NSString).lastPathComponent } ?? (path as NSString).lastPathComponent
        return first.hasPrefix("-") ? String(first.dropFirst()) : first
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "nu"]

    var isShell: Bool { Self.shells.contains(executableName) }

    /// `sh -c …` style invocation (including combined flags like `-lc`).
    var isShellCommand: Bool {
        isShell && args.dropFirst().contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }
    }

    /// A login/interactive shell such as a terminal tab — never a job by itself.
    var isInteractiveShell: Bool {
        isShell && !isShellCommand && args.dropFirst().allSatisfy { $0.hasPrefix("-") }
    }

    /// The script passed to `sh -c`.
    var shellScript: String? {
        guard isShellCommand else { return nil }
        return args.dropFirst().first { !$0.hasPrefix("-") }
    }
}

/// A process tree started by an agent, rooted at the topmost non-harness process.
struct AgentJob: Identifiable, Sendable {
    let id: String
    let root: ProcInfo
    let processes: [ProcInfo]
    let harness: Harness
    let via: Harness?
    /// The agent session that spawned it is gone: the root was reparented to launchd
    /// and is only attributed through inherited environment markers.
    let isGhost: Bool
    let command: String
    let fullCommand: String
    let cwd: String?

    var ports: [UInt16] {
        Array(Set(processes.flatMap { $0.ports.map(\.port) })).sorted()
    }

    func addresses(for port: UInt16) -> [String] {
        Array(Set(processes.flatMap { $0.ports.filter { $0.port == port }.map(\.address) })).sorted()
    }

    var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }

    /// Summed over the tree; nil until a second scan gives a baseline.
    var cpu: Double? {
        let samples = processes.compactMap(\.cpu)
        return samples.isEmpty ? nil : samples.reduce(0, +)
    }
}

struct Snapshot: Sendable {
    var jobs: [AgentJob] = []
    /// All known processes, for computing subtrees at kill time.
    var children: [pid_t: [pid_t]] = [:]
}

final class ProcessScanner: @unchecked Sendable {
    private var argBuffer: [UInt8]
    private let myUID = getuid()
    private let myPID = getpid()
    /// CPU time (ns) per process at the previous scan, to turn into a percentage.
    private var cpuSamples: [pid_t: (started: Date, cpuTime: UInt64, at: UInt64)] = [:]
    static let home = NSHomeDirectory()

    init() {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&mib, 2, &argmax, &size, nil, 0) != 0 || argmax <= 0 { argmax = 1 << 20 }
        argBuffer = [UInt8](repeating: 0, count: Int(argmax))
    }

    func scan() -> Snapshot {
        // 1. Process table.
        var procs: [pid_t: ProcInfo] = [:]
        var parents: [pid_t: pid_t] = [:]
        for pid in Self.allPids() {
            guard let bsd = Self.bsdInfo(pid) else { continue }
            parents[pid] = pid_t(bsd.pbi_ppid)
            guard bsd.pbi_uid == myUID, pid != myPID, bsd.pbi_status != 5 /* SZOMB */ else { continue }
            guard let path = Self.path(pid), !path.hasSuffix("/Reaper.app/Contents/MacOS/Reaper") else { continue }
            let (args, env) = argsAndEnv(pid) ?? ([], [:])
            let started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)
                               + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
            procs[pid] = ProcInfo(pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid, path: path,
                                  args: args, markerEnv: env, started: started)
        }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, ppid) in parents { children[ppid, default: []].append(pid) }

        // 2. Which processes are harnesses themselves.
        var harnessOf: [pid_t: Harness] = [:]
        for (pid, p) in procs {
            if let h = HarnessMatcher.harness(executable: p.path, args: p.args) { harnessOf[pid] = h }
        }

        // 3. Attribution: nearest harness ancestor, else env markers.
        func attribution(_ pid: pid_t) -> (Harness, Harness?)? {
            var chain: [Harness] = []
            var q = parents[pid] ?? 0
            var guardCount = 0
            while q > 1, guardCount < 512 {
                if let a = procs[q] {
                    if chain.isEmpty, HarnessMatcher.isNoise(path: a.path, args: a.args) { return nil }
                    if harnessOf[q] != nil, HarnessMatcher.isEditorHost(args: a.args) { return nil }
                }
                if let h = harnessOf[q], chain.last != h { chain.append(h) }
                q = parents[q] ?? 0
                guardCount += 1
            }
            if let nearest = chain.first {
                return (nearest, chain.last(where: { $0 != nearest }))
            }
            if let p = procs[pid], let env = HarnessMatcher.harness(env: p.markerEnv) { return env }
            return nil
        }

        var candidates: [pid_t: (Harness, Harness?)] = [:]
        for (pid, p) in procs where harnessOf[pid] == nil && !p.isInteractiveShell
            && !HarnessMatcher.isNoise(path: p.path, args: p.args) {
            if let a = attribution(pid) { candidates[pid] = a }
        }

        // 4. Group into jobs by topmost candidate ancestor.
        func root(of pid: pid_t) -> pid_t {
            var r = pid
            while let parent = parents[r], parent > 1, candidates[parent] != nil { r = parent }
            return r
        }
        var groups: [pid_t: [pid_t]] = [:]
        for pid in candidates.keys { groups[root(of: pid), default: []].append(pid) }

        // 5. Build jobs, fetching ports/cwd/usage only for what we show.
        let now = DispatchTime.now().uptimeNanoseconds
        var samples: [pid_t: (started: Date, cpuTime: UInt64, at: UInt64)] = [:]
        var jobs: [AgentJob] = []
        for (rootPID, members) in groups {
            guard var rootInfo = procs[rootPID], let (harness, via) = candidates[rootPID] else { continue }
            var members = members.compactMap { procs[$0] }
            for i in members.indices {
                let p = members[i]
                members[i].ports = Self.listeningPorts(p.pid)
                guard let usage = Self.usage(p.pid) else { continue }
                members[i].memory = usage.memory
                if let prev = cpuSamples[p.pid], prev.started == p.started, now > prev.at {
                    let used = usage.cpuTime >= prev.cpuTime ? usage.cpuTime - prev.cpuTime : 0
                    members[i].cpu = Double(used) / Double(now - prev.at) * 100
                }
                samples[p.pid] = (p.started, usage.cpuTime, now)
            }
            members.sort { $0.started < $1.started }
            if let rp = members.first(where: { $0.pid == rootPID }) { rootInfo = rp }

            let (short, full) = Self.describe(rootInfo, children: children, procs: procs)
            jobs.append(AgentJob(
                id: "\(rootPID)-\(rootInfo.started.timeIntervalSince1970)",
                root: rootInfo, processes: members, harness: harness, via: via,
                isGhost: rootInfo.ppid == 1,
                command: short, fullCommand: full, cwd: Self.cwd(rootPID)))
        }
        cpuSamples = samples
        // Ghosts first, then longest running.
        jobs.sort {
            if $0.isGhost != $1.isGhost { return $0.isGhost }
            return $0.root.started < $1.root.started
        }
        return Snapshot(jobs: jobs, children: children)
    }

    // MARK: - Command formatting

    /// Short and full display strings. `sh -c` wrappers show the program they run.
    static func describe(_ p: ProcInfo, children: [pid_t: [pid_t]], procs: [pid_t: ProcInfo]) -> (String, String) {
        if p.isShellCommand {
            if let script = p.shellScript.map(cleanScript) {
                let oneLine = script.split(whereSeparator: \.isNewline).joined(separator: " ")
                return (oneLine, script)
            }
            let kids = (children[p.pid] ?? []).compactMap { procs[$0] }.sorted { $0.started < $1.started }
            if let kid = kids.first { return describe(kid, children: children, procs: procs) }
        }
        let full = p.args.isEmpty ? p.path : p.args.joined(separator: " ")
        return (format(p), full)
    }

    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "tsx", "ts-node"]
    /// Interpreter flags that consume the following argument.
    private static let flagsWithValue: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader", "-m"]
    private static let packageManagers: Set<String> = ["npm", "npx", "yarn", "pnpm", "pnpx", "bun", "bunx"]

    /// e.g. `node …/yarn/bin/yarn.js dev` → `yarn dev`, `node …/node_modules/astro/bin/astro.mjs preview` → `astro preview`.
    private static func format(_ p: ProcInfo) -> String {
        let args = p.args.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !args.isEmpty else { return (p.path as NSString).lastPathComponent }
        var words = [p.executableName]
        var rest = Array(args.dropFirst())

        if interpreters.contains(p.executableName) {
            var i = 0
            while i < rest.count, rest[i].hasPrefix("-") {
                i += flagsWithValue.contains(rest[i]) ? 2 : 1
            }
            if i < rest.count, let tool = toolName(forScript: rest[i]) {
                words = [tool]
                rest = Array(rest[(i + 1)...])
                // `corepack pnpm …` → `pnpm …`
                if tool == "corepack", let next = rest.first, packageManagers.contains(next) {
                    words = [next]
                    rest.removeFirst()
                }
            }
        }
        return (words + rest.map(shortArg)).joined(separator: " ")
    }

    /// A friendly name for a script run by an interpreter, if it's recognisably a tool.
    private static func toolName(forScript script: String) -> String? {
        let base = (script as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        if stem == "yarn" || stem.hasPrefix("yarn-") { return "yarn" }
        if stem == "npm-cli" { return "npm" }
        if stem == "npx-cli" { return "npx" }
        if stem == "pnpm" || stem == "pnpx" || stem == "corepack" { return stem }
        if let r = script.range(of: "/node_modules/", options: .backwards) {
            var parts = script[r.upperBound...].split(separator: "/").map(String.init)
            if parts.first == ".bin", parts.count > 1 { return parts[1] }
            guard let first = parts.first else { return nil }
            if first.hasPrefix("@"), parts.count > 1 { parts = [first + "/" + parts[1]] }
            return parts[0]
        }
        return nil
    }

    private static func shortArg(_ arg: String) -> String {
        var a = arg
        if let r = a.range(of: "/node_modules/", options: .backwards) {
            a = String(a[r.upperBound...])
            if a.hasPrefix(".bin/") { a.removeFirst(5) }
        } else if a.hasPrefix(home) {
            a = "~" + a.dropFirst(home.count)
        }
        return a.contains(" ") ? "\"\(a)\"" : a
    }

    /// Unwrap Claude Code's `source <snapshot> && eval '<cmd>' < /dev/null && pwd …` wrapper.
    private static func cleanScript(_ script: String) -> String {
        guard let start = script.range(of: "eval '") else { return script }
        let tail = script[start.upperBound...]
        let end = tail.range(of: "' < /dev/null", options: .backwards)
            ?? tail.range(of: "'", options: .backwards)
        let inner = end.map { tail[..<$0.lowerBound] } ?? tail
        return inner
            .replacingOccurrences(of: "'\"'\"'", with: "'")
            .replacingOccurrences(of: "'\\''", with: "'")
    }

    // MARK: - libproc

    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
    }()

    /// Memory footprint (bytes) and total user + system CPU time (ns).
    static func usage(_ pid: pid_t) -> (memory: UInt64, cpuTime: UInt64)? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        // CPU times are in mach ticks, not nanoseconds, on Apple silicon.
        let ticks = info.ri_user_time + info.ri_system_time
        return (info.ri_phys_footprint, ticks * timebase.numer / timebase.denom)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// Arguments plus the subset of environment variables in `HarnessMatcher.markerKeys`.
    private func argsAndEnv(_ pid: pid_t) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argBuffer.count
        let ok = argBuffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard ok == 0, size > MemoryLayout<Int32>.size else { return nil }

        return argBuffer.withUnsafeBytes { raw -> ([String], [String: String]) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let argc = Int(raw.loadUnaligned(as: Int32.self))
            var i = MemoryLayout<Int32>.size
            while i < size, bytes[i] != 0 { i += 1 }   // exec path
            while i < size, bytes[i] == 0 { i += 1 }   // padding

            func next() -> String? {
                guard i < size else { return nil }
                let start = i
                while i < size, bytes[i] != 0 { i += 1 }
                let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
                i += 1
                return s
            }

            var args: [String] = []
            for _ in 0..<argc { guard let a = next() else { break }; args.append(a) }
            var env: [String: String] = [:]
            while let e = next(), !e.isEmpty {
                guard let eq = e.firstIndex(of: "=") else { continue }
                let key = String(e[..<eq])
                if HarnessMatcher.markerKeys.contains(key) { env[key] = String(e[e.index(after: eq)...]) }
            }
            return (args, env)
        }
    }

    static func listeningPorts(_ pid: pid_t) -> [ListenPort] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufSize) / stride + 16)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }

        var result = Set<ListenPort>()
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let sz = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, sz) == sz,
                  si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            result.insert(ListenPort(port: port, address: address(ini)))
        }
        return Array(result)
    }

    private static func address(_ ini: in_sockinfo) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var raw: String
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var a = ini.insi_laddr.ina_46.i46a_addr4
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            raw = String(cString: buf)
        } else {
            var a = ini.insi_laddr.ina_6
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
            raw = String(cString: buf)
        }
        switch raw {
        case "0.0.0.0", "::": raw = "*"
        case "127.0.0.1", "::1": raw = "localhost"
        default: break
        }
        return raw
    }
}
