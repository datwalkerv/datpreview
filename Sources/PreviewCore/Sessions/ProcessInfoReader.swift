import Darwin
import Foundation

/// Minimal process-table access via sysctl (no subprocesses, no permissions needed).
public struct ProcessSnapshot: Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let tty: String?
    public let name: String
}

public enum ProcessTable {
    public static func info(_ pid: pid_t) -> ProcessSnapshot? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = kinfo.kp_eproc.e_ppid
        let tdev = kinfo.kp_eproc.e_tdev
        var tty: String?
        if tdev != -1, let name = devname(tdev, S_IFCHR) { tty = String(cString: name) }
        let comm = withUnsafeBytes(of: kinfo.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessSnapshot(pid: pid, ppid: ppid, tty: tty, name: comm)
    }

    /// Ancestors from the parent upwards (excluding pid itself), stopping at launchd.
    public static func ancestors(of pid: pid_t) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var current = info(pid)?.ppid ?? 0
        while current > 1, result.count < 64, let p = info(current) {
            result.append(p)
            current = p.ppid
        }
        return result
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
