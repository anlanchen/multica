// Process-level measurements for comparing two macOS apps.
//
//   swiftc -O scripts/perf/probe.swift -o .build/probe
//   .build/probe snapshot /Applications/Multica.app            # processes, memory, threads (JSON)
//   .build/probe idle /Applications/Multica.app 60             # CPU over an idle interval (JSON)
//   .build/probe launch dist/Multica.app [args...]             # time to first on-screen window (JSON)
//
// A process belongs to an app when its executable lives inside the bundle
// (Electron helpers live in Contents/Frameworks). Executables under
// `--exclude <substring>` (e.g. the bundled agent daemon) are reported
// separately so both clients are compared on the UI processes alone.
import AppKit
import Darwin
import Foundation

struct ProcInfo: Codable {
    var pid: Int32
    var name: String
    var path: String
    var footprintMB: Double
    var residentMB: Double
    var threads: Int32
    var cpuSeconds: Double
}

func allPIDs() -> [Int32] {
    let n = proc_listallpids(nil, 0)
    var pids = [Int32](repeating: 0, count: Int(n) * 2)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
    return Array(pids.prefix(Int(got))).filter { $0 > 0 }
}

func path(of pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}

var timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

func info(_ pid: Int32) -> ProcInfo? {
    guard let p = path(of: pid) else { return nil }
    var usage = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &usage) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return nil }
    var task = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let threads = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size ? task.pti_threadnum : 0
    let ticks = Double(usage.ri_user_time + usage.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
    return ProcInfo(pid: pid, name: (p as NSString).lastPathComponent, path: p,
                    footprintMB: Double(usage.ri_phys_footprint) / 1_048_576,
                    residentMB: Double(usage.ri_resident_size) / 1_048_576,
                    threads: threads, cpuSeconds: ticks / 1e9)
}

func processes(in bundle: String, exclude: [String]) -> (app: [ProcInfo], excluded: [ProcInfo]) {
    let root = (bundle as NSString).standardizingPath + "/"
    var app: [ProcInfo] = [], other: [ProcInfo] = []
    for pid in allPIDs() {
        guard let p = path(of: pid), p.hasPrefix(root), let i = info(pid) else { continue }
        if exclude.contains(where: { p.contains($0) }) { other.append(i) } else { app.append(i) }
    }
    return (app.sorted { $0.pid < $1.pid }, other)
}

struct Snapshot: Codable {
    var bundle: String
    var processes: [ProcInfo]
    var excluded: [ProcInfo]
    var processCount: Int
    var totalFootprintMB: Double
    var totalResidentMB: Double
    var totalThreads: Int32
}

func snapshot(_ bundle: String, exclude: [String]) -> Snapshot {
    let (app, other) = processes(in: bundle, exclude: exclude)
    return Snapshot(bundle: bundle, processes: app, excluded: other, processCount: app.count,
                    totalFootprintMB: app.reduce(0) { $0 + $1.footprintMB },
                    totalResidentMB: app.reduce(0) { $0 + $1.residentMB },
                    totalThreads: app.reduce(0) { $0 + $1.threads })
}

func emit<T: Encodable>(_ value: T) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! e.encode(value), as: UTF8.self))
}

var args = Array(CommandLine.arguments.dropFirst())
var exclude: [String] = []
while let i = args.firstIndex(of: "--exclude"), i + 1 < args.count {
    exclude.append(args[i + 1])
    args.removeSubrange(i...(i + 1))
}
guard let command = args.first, args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: probe snapshot|idle|launch <bundle> [seconds|args...] [--exclude substr]\n".utf8))
    exit(2)
}
let bundle = URL(fileURLWithPath: args[1]).standardizedFileURL.path

switch command {
case "snapshot":
    emit(snapshot(bundle, exclude: exclude))

case "idle":
    struct Idle: Codable { var seconds: Double; var cpuPercent: Double; var perProcess: [String: Double]; var footprintStartMB: Double; var footprintEndMB: Double; var wakeups: Int? }
    let seconds = Double(args.count > 2 ? args[2] : "60") ?? 60
    let start = processes(in: bundle, exclude: exclude).app
    Thread.sleep(forTimeInterval: seconds)
    let end = processes(in: bundle, exclude: exclude).app
    var per: [String: Double] = [:]
    var total = 0.0
    for e in end {
        let before = start.first { $0.pid == e.pid }?.cpuSeconds ?? e.cpuSeconds
        let pct = (e.cpuSeconds - before) / seconds * 100
        per["\(e.name) [\(e.pid)]"] = (pct * 100).rounded() / 100
        total += pct
    }
    emit(Idle(seconds: seconds, cpuPercent: (total * 100).rounded() / 100, perProcess: per,
              footprintStartMB: start.reduce(0) { $0 + $1.footprintMB }, footprintEndMB: end.reduce(0) { $0 + $1.footprintMB }))

case "launch":
    struct Launch: Codable { var firstWindowMs: Double; var pid: Int32; var footprintAtWindowMB: Double; var footprintAfter5sMB: Double; var processCountAfter5s: Int }
    let exe: String = {
        let plist = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")
        let name = plist?["CFBundleExecutable"] as? String ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        return bundle + "/Contents/MacOS/" + name
    }()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = Array(args.dropFirst(2))
    let t0 = Date()
    try! p.run()
    let pid = p.processIdentifier
    var firstWindow: Double = -1
    while Date().timeIntervalSince(t0) < 60 {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = Set(processes(in: bundle, exclude: exclude).app.map(\.pid))
        if windows.contains(where: { w in
            guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owned.contains(owner) || owner == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any], (b["Width"] as? Double ?? 0) > 200 else { return false }
            return true
        }) {
            firstWindow = Date().timeIntervalSince(t0) * 1000
            break
        }
        usleep(5_000)
    }
    let atWindow = snapshot(bundle, exclude: exclude).totalFootprintMB
    Thread.sleep(forTimeInterval: 5)
    let after = snapshot(bundle, exclude: exclude)
    emit(Launch(firstWindowMs: (firstWindow * 10).rounded() / 10, pid: pid, footprintAtWindowMB: atWindow,
                footprintAfter5sMB: after.totalFootprintMB, processCountAfter5s: after.processCount))

case "windows":
    let owned = Set(processes(in: bundle, exclude: exclude).app.map(\.pid))
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in windows {
        guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owned.contains(owner), (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print("\(w[kCGWindowNumber as String] ?? 0)\t\(Int(b["Width"] as? Double ?? 0))x\(Int(b["Height"] as? Double ?? 0))\t\(w[kCGWindowName as String] ?? "")")
    }

default:
    FileHandle.standardError.write(Data("unknown command \(command)\n".utf8))
    exit(2)
}
