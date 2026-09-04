import AppKit
import Darwin
import Foundation

/// A detected AI agent / host app that may be keeping work alive.
struct ActiveAgent: Identifiable, Equatable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let statusHint: String
    let activeSince: Date
    let pid: pid_t
    /// When true, Stay Awake should hold sleep for this agent.
    let isBusy: Bool

    var elapsedDescription: String {
        let elapsed = max(0, Int(Date().timeIntervalSince(activeSince)))
        let mins = elapsed / 60
        let secs = elapsed % 60
        if mins >= 60 {
            let hours = mins / 60
            let rem = mins % 60
            return String(format: "%dh %02dm", hours, rem)
        }
        return String(format: "%dm %02ds", mins, secs)
    }

    static func == (lhs: ActiveAgent, rhs: ActiveAgent) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.statusHint == rhs.statusHint
            && lhs.pid == rhs.pid
            && lhs.isBusy == rhs.isBusy
    }
}

/// Lightweight multi-agent activity detector.
/// IDE hosts like Cursor are detected via the app + helper process tree (not main PID CPU alone).
@MainActor
final class AgentActivityWatcher: ObservableObject {
    static let shared = AgentActivityWatcher()

    @Published private(set) var isAnyAgentActive = false
    @Published private(set) var activeAgents: [ActiveAgent] = []
    @Published private(set) var activeAgentNames: [String] = []

    private var timer: Timer?
    private var workingUntil: Date?
    private var previousCPU: [pid_t: (time: UInt64, stamp: CFAbsoluteTime)] = [:]
    private var firstSeen: [String: Date] = [:]

    private struct HostSpec {
        let bundleID: String
        let pathHints: [String]
        /// Main-process CPU alone is unreliable for Electron; tree CPU matters more.
        let treeBusyThreshold: Double
        let alwaysShowWhenRunning: Bool
    }

    private let hosts: [HostSpec] = [
        HostSpec(
            bundleID: "com.todesktop.230313mzl4w4u92",
            pathHints: ["Cursor.app", "Cursor Helper"],
            treeBusyThreshold: 4,
            alwaysShowWhenRunning: true
        ),
        HostSpec(
            bundleID: "com.microsoft.VSCode",
            pathHints: ["Visual Studio Code.app", "Code Helper"],
            treeBusyThreshold: 5,
            alwaysShowWhenRunning: true
        ),
        HostSpec(
            bundleID: "com.microsoft.VSCodeInsiders",
            pathHints: ["Visual Studio Code - Insiders.app", "Code - Insiders Helper"],
            treeBusyThreshold: 5,
            alwaysShowWhenRunning: true
        ),
        HostSpec(
            bundleID: "com.openai.chat",
            pathHints: ["ChatGPT.app"],
            treeBusyThreshold: 3,
            alwaysShowWhenRunning: true
        ),
        HostSpec(
            bundleID: "com.anthropic.claudefordesktop",
            pathHints: ["Claude.app"],
            treeBusyThreshold: 3,
            alwaysShowWhenRunning: true
        ),
        HostSpec(
            bundleID: "com.github.CopilotForXcode",
            pathHints: ["Copilot"],
            treeBusyThreshold: 3,
            alwaysShowWhenRunning: false
        ),
    ]

    private let debounceSeconds: TimeInterval = 5 * 60
    private let cliCPUBusyThreshold = 3.0

    private init() {}

    func start() {
        guard timer == nil else { return }
        tick()
        // Faster while watching — Cursor helpers spike between quiet thinks.
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isAnyAgentActive = false
        activeAgents = []
        activeAgentNames = []
        workingUntil = nil
        previousCPU.removeAll()
        firstSeen.removeAll()
    }

    func icon(for agent: ActiveAgent) -> NSImage? {
        if agent.pid > 0,
           let app = NSRunningApplication(processIdentifier: agent.pid),
           let icon = app.icon {
            return icon
        }
        if let bid = agent.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func tick() {
        let sample = sampleAgents()
        let busyHits = sample.filter(\.isBusy)

        if !busyHits.isEmpty {
            workingUntil = Date().addingTimeInterval(debounceSeconds)
        }

        let inDebounce = workingUntil.map { Date() < $0 } ?? false
        isAnyAgentActive = !busyHits.isEmpty || inDebounce

        var display = sample
        if display.isEmpty, inDebounce, !activeAgents.isEmpty {
            display = activeAgents.map {
                ActiveAgent(
                    id: $0.id,
                    displayName: $0.displayName,
                    bundleIdentifier: $0.bundleIdentifier,
                    statusHint: "Between steps…",
                    activeSince: firstSeen[$0.id] ?? $0.activeSince,
                    pid: $0.pid,
                    isBusy: true
                )
            }
        }

        let ids = Set(display.map(\.id))
        firstSeen = firstSeen.filter { ids.contains($0.key) }
        for agent in display where firstSeen[agent.id] == nil {
            firstSeen[agent.id] = agent.activeSince
        }

        activeAgents = display.map { agent in
            ActiveAgent(
                id: agent.id,
                displayName: agent.displayName,
                bundleIdentifier: agent.bundleIdentifier,
                statusHint: agent.statusHint,
                activeSince: firstSeen[agent.id] ?? agent.activeSince,
                pid: agent.pid,
                isBusy: agent.isBusy
            )
        }
        activeAgentNames = activeAgents.map(\.displayName)

        if !isAnyAgentActive {
            workingUntil = nil
        }
    }

    private func sampleAgents() -> [ActiveAgent] {
        var agents: [ActiveAgent] = []
        let processSnapshot = Self.listAllProcesses()

        for host in hosts {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == host.bundleID && !$0.isTerminated
            }) else { continue }

            let treeCPU = treeCPU(for: host, appPID: app.processIdentifier, processes: processSnapshot)
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            // Electron agent UIs often sit near-idle between tool calls; frontmost host counts.
            let busy = treeCPU >= host.treeBusyThreshold || frontmost
            let label = app.localizedName ?? host.bundleID

            if busy || host.alwaysShowWhenRunning {
                let hint: String
                if busy && treeCPU >= host.treeBusyThreshold {
                    hint = statusHint(forCPU: treeCPU, kind: .ide)
                } else if frontmost {
                    hint = "Frontmost · agent host"
                } else {
                    hint = "Open · watching"
                }
                agents.append(
                    ActiveAgent(
                        id: "app:\(host.bundleID)",
                        displayName: label,
                        bundleIdentifier: host.bundleID,
                        statusHint: hint,
                        activeSince: Date(),
                        pid: app.processIdentifier,
                        isBusy: busy
                    )
                )
            }
        }

        for entry in processSnapshot where Self.isCLIAgentName(entry.baseName) {
            let cpu = cpuPercent(for: entry.pid)
            let busy = cpu >= cliCPUBusyThreshold
            guard busy else { continue }
            agents.append(
                ActiveAgent(
                    id: "cli:\(entry.baseName)",
                    displayName: Self.prettyCLIName(entry.baseName),
                    bundleIdentifier: Self.bundleHint(forCLI: entry.baseName),
                    statusHint: statusHint(forCPU: cpu, kind: .cli),
                    activeSince: Date(),
                    pid: entry.pid,
                    isBusy: true
                )
            )
        }

        var seen = Set<String>()
        return agents.filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.isBusy != $1.isBusy { return $0.isBusy && !$1.isBusy }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private func treeCPU(for host: HostSpec, appPID: pid_t, processes: [ProcEntry]) -> Double {
        var total = cpuPercent(for: appPID)
        for entry in processes {
            let pathMatch = host.pathHints.contains { hint in
                entry.path.localizedCaseInsensitiveContains(hint)
            }
            guard pathMatch, entry.pid != appPID else { continue }
            total += cpuPercent(for: entry.pid)
        }
        return total
    }

    private enum AgentKind { case ide, cli }

    private func statusHint(forCPU cpu: Double, kind: AgentKind) -> String {
        if cpu >= 35 { return kind == .cli ? "Running tools" : "Heavy agent work" }
        if cpu >= 10 { return "Working…" }
        if cpu >= 4 { return "Agent activity" }
        return "Active"
    }

    private static func isCLIAgentName(_ base: String) -> Bool {
        base == "claude" || base == "codex" || base == "aider"
            || base == "ollama" || base == "gemini" || base.hasPrefix("copilot")
            || base == "cursor-agent"
    }

    private static func prettyCLIName(_ base: String) -> String {
        switch base {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "aider": return "Aider"
        case "ollama": return "Ollama"
        case "gemini": return "Gemini CLI"
        case "cursor-agent": return "Cursor Agent"
        default:
            if base.hasPrefix("copilot") { return "Copilot" }
            return base.capitalized
        }
    }

    private static func bundleHint(forCLI base: String) -> String? {
        switch base {
        case "claude": return "com.anthropic.claudefordesktop"
        case "codex": return "com.openai.chat"
        case "cursor-agent": return "com.todesktop.230313mzl4w4u92"
        default: return nil
        }
    }

    private func cpuPercent(for pid: pid_t) -> Double {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard result == size else { return 0 }

        let total = info.pti_total_user + info.pti_total_system
        let now = CFAbsoluteTimeGetCurrent()
        defer { previousCPU[pid] = (total, now) }

        guard let prev = previousCPU[pid] else { return 0 }
        let dt = now - prev.stamp
        guard dt > 0.2 else { return 0 }
        let delta = total &- prev.time
        return Double(delta) / (dt * 1_000_000_000.0) * 100.0
    }

    private struct ProcEntry {
        let pid: pid_t
        let path: String
        var baseName: String { (path as NSString).lastPathComponent.lowercased() }
    }

    private static func listAllProcesses() -> [ProcEntry] {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride + 16)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        let n = Int(count) / MemoryLayout<pid_t>.stride

        var result: [ProcEntry] = []
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for i in 0..<n {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLen > 0 else { continue }
            let path = String(decoding: pathBuffer.prefix(Int(pathLen)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(ProcEntry(pid: pid, path: path))
        }
        return result
    }
}
