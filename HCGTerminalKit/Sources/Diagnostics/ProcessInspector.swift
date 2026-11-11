import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProcessEntry: Hashable, Sendable, Identifiable {
    public var pid: Int32
    public var parentPID: Int32
    public var userID: UInt32
    public var name: String
    public var id: Int32 { pid }

    public init(pid: Int32, parentPID: Int32, userID: UInt32, name: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
    }
}

public enum ProcessListing: Sendable, Equatable {
    /// Processes visible to this app. `complete` is false when the system only revealed a
    /// subset (typical of the iOS sandbox).
    case listed([ProcessEntry], complete: Bool)
    case restricted(String)
}

/// Read-only process inspection using the APIs the platform exposes. Reports exactly what the
/// system reveals; it never tries to widen its view.
public enum ProcessInspector {
    public static func listProcesses() -> ProcessListing {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return .restricted("The process table is not accessible from this app (\(String(cString: strerror(errno)))).")
        }
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = buffer.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
            return .restricted("The process table is not accessible from this app (\(String(cString: strerror(errno)))).")
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        let entries: [ProcessEntry] = buffer.prefix(count).map { info in
            var proc = info
            let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return ProcessEntry(pid: info.kp_proc.p_pid, parentPID: info.kp_eproc.e_ppid, userID: info.kp_eproc.e_ucred.cr_uid, name: name)
        }
        let ownPID = getpid()
        let onlySelf = entries.allSatisfy { $0.pid == ownPID }
        return .listed(entries.sorted { $0.pid < $1.pid }, complete: !onlySelf)
        #elseif os(Linux)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
            return .restricted("/proc is not readable.")
        }
        var entries: [ProcessEntry] = []
        for name in names where name.allSatisfy(\.isNumber) {
            guard let pid = Int32(name),
                  let status = try? String(contentsOfFile: "/proc/\(name)/status", encoding: .utf8) else { continue }
            var command = "?"
            var ppid: Int32 = 0
            var uid: UInt32 = 0
            for line in status.split(separator: "\n") {
                if line.hasPrefix("Name:") { command = line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("PPid:") { ppid = Int32(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) ?? 0 }
                if line.hasPrefix("Uid:") {
                    uid = UInt32(line.dropFirst(4).split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "0") ?? 0
                }
            }
            entries.append(ProcessEntry(pid: pid, parentPID: ppid, userID: uid, name: command))
        }
        return .listed(entries.sorted { $0.pid < $1.pid }, complete: true)
        #else
        return .restricted("Process inspection is not supported on this platform.")
        #endif
    }
}

/// A point-in-time snapshot of the device, using public APIs only.
public struct SystemSnapshot: Sendable, Hashable {
    public var operatingSystem: String
    public var hardwareIdentifier: String
    public var processorCount: Int
    public var physicalMemory: UInt64
    public var systemUptime: TimeInterval
    public var thermalState: String
    public var lowPowerMode: Bool?
    public var sandboxFreeBytes: Int64?
    public var sandboxTotalBytes: Int64?
    public var effectiveUserID: UInt32
    public var processID: Int32

    public static func capture(sandboxURL: URL? = nil) -> SystemSnapshot {
        let info = ProcessInfo.processInfo
        var name = utsname()
        var machine = "unknown"
        if uname(&name) == 0 {
            machine = withUnsafeBytes(of: &name.machine) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        var free: Int64?
        var total: Int64?
        if let url = sandboxURL, let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path) {
            free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
            total = (attributes[.systemSize] as? NSNumber)?.int64Value
        }
        #if canImport(Darwin)
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        #else
        let thermal = "Not reported on this platform"
        #endif
        #if os(iOS) || os(macOS)
        let lowPower: Bool? = info.isLowPowerModeEnabled
        #else
        let lowPower: Bool? = nil
        #endif
        return SystemSnapshot(
            operatingSystem: info.operatingSystemVersionString,
            hardwareIdentifier: machine,
            processorCount: info.activeProcessorCount,
            physicalMemory: info.physicalMemory,
            systemUptime: info.systemUptime,
            thermalState: thermal,
            lowPowerMode: lowPower,
            sandboxFreeBytes: free,
            sandboxTotalBytes: total,
            effectiveUserID: UInt32(geteuid()),
            processID: getpid()
        )
    }

    public var lines: [(String, String)] {
        var rows: [(String, String)] = [
            ("Operating system", operatingSystem),
            ("Hardware", hardwareIdentifier),
            ("Processors", "\(processorCount)"),
            ("Memory", ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)),
            ("Uptime", Self.duration(systemUptime)),
            ("Thermal state", thermalState),
            ("Effective user ID", "\(effectiveUserID)"),
            ("Process ID", "\(processID)"),
        ]
        if let lowPowerMode { rows.append(("Low Power Mode", lowPowerMode ? "On" : "Off")) }
        if let sandboxFreeBytes, let sandboxTotalBytes {
            rows.append(("Storage free", "\(ByteCountFormatter.string(fromByteCount: sandboxFreeBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: sandboxTotalBytes, countStyle: .file))"))
        }
        return rows
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let days = total / 86_400, hours = (total % 86_400) / 3600, minutes = (total % 3600) / 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }
}
