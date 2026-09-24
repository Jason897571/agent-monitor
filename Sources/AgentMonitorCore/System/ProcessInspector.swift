import Darwin
import Foundation

/// Read-only inspection of other processes via `sysctl`.
///
/// Everything here works for same-user processes with no entitlement, no TCC prompt
/// and no root. Note the one hard limit, verified empirically: the kernel omits the
/// environment block for **code-signing-restricted** targets (`cs_restricted`), which
/// covers every SIP binary including `/bin/zsh` and `/bin/bash`. `sudo` does not help —
/// the gate is not uid-based. So `environment(of:)` returns an empty dictionary for the
/// parent login shell, always. `claude` itself is not restricted, so reading *its*
/// environment works. See DESIGN.md §7.4.
public enum ProcessInspector {

    public struct Info: Sendable, Equatable {
        public let pid: pid_t
        /// `p_comm`, truncated by the kernel to 16 characters.
        public let command: String
        /// True process start time, straight from the kernel. No string parsing,
        /// no timezone ambiguity — unlike the `procStart` field agents write to disk.
        public let startTime: Date
    }

    // MARK: - Single process

    public static func info(of pid: pid_t) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let rc = mib.withUnsafeMutableBufferPointer { mibBuffer in
            sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), &proc, &size, nil, 0)
        }
        // A dead pid yields rc == 0 with size == 0 rather than an error, so the size
        // check is load-bearing.
        guard rc == 0, size > 0, proc.kp_proc.p_pid == pid else { return nil }

        return Info(pid: pid, command: command(of: proc), startTime: startTime(of: proc))
    }

    /// Cheap existence check. `EPERM` means the process exists but belongs to another
    /// user, which still counts as existing.
    public static func exists(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Ancestry

    /// The parent of `pid`, or `nil` if it is gone.
    public static func parent(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { mibBuffer in
            sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), &proc, &size, nil, 0)
        }
        guard rc == 0, size > 0, proc.kp_proc.p_pid == pid else { return nil }
        return proc.kp_eproc.e_ppid
    }

    /// `pid` and each of its ancestors, nearest first, stopping before launchd.
    public static func ancestry(of pid: pid_t) -> [pid_t] {
        ancestry(of: pid, parent: { parent(of: $0) })
    }

    /// The walk itself, with the parent lookup injected so it can be tested without a
    /// real process tree. Bounded, because a corrupt or racing table must not hang it.
    static func ancestry(of pid: pid_t, parent: (pid_t) -> pid_t?, limit: Int = 64) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while current > 1, chain.count < limit, !chain.contains(current) {
            chain.append(current)
            guard let next = parent(current) else { break }
            current = next
        }
        return chain
    }

    // MARK: - Enumeration

    /// All processes whose `p_comm` is one of `names`.
    ///
    /// Takes a set rather than a single name because the same program can present
    /// different `p_comm` values depending on how it was installed — see `ClaudeProcess`.
    public static func processes(matching names: Set<String>) -> [Info] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard mib.withUnsafeMutableBufferPointer({
            sysctl($0.baseAddress, u_int($0.count), nil, &size, nil, 0)
        }) == 0, size > 0 else { return [] }

        // The table can grow between sizing and reading; over-allocate a little.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride

        let rc = procs.withUnsafeMutableBufferPointer { procBuffer in
            mib.withUnsafeMutableBufferPointer { mibBuffer in
                sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count),
                       procBuffer.baseAddress, &size, nil, 0)
            }
        }
        guard rc == 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(count).compactMap { proc in
            guard proc.kp_proc.p_pid > 0 else { return nil }
            let name = command(of: proc)
            guard names.contains(name) else { return nil }
            return Info(pid: proc.kp_proc.p_pid,
                        command: name,
                        startTime: startTime(of: proc))
        }
    }

    // MARK: - Environment

    /// The target's environment at `exec` time.
    ///
    /// Returns `[:]` — not an error — when the kernel withholds it. Detect failure by
    /// an empty result, never by a return code: the syscall succeeds and silently
    /// truncates the buffer to the end of `argv`.
    public static func environment(of pid: pid_t) -> [String: String] {
        guard let raw = procArgs(of: pid) else { return [:] }
        var env: [String: String] = [:]
        for entry in raw.environment {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return env
    }

    public static func arguments(of pid: pid_t) -> [String] {
        procArgs(of: pid)?.arguments ?? []
    }

    // MARK: - Private

    private static func command(of proc: kinfo_proc) -> String {
        withUnsafePointer(to: proc.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func startTime(of proc: kinfo_proc) -> Date {
        let tv = proc.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    private struct ProcArgs {
        let arguments: [String]
        let environment: [String]
    }

    /// `KERN_PROCARGS2` layout: `int32 argc`, exec path, NUL padding, `argc` NUL-separated
    /// arguments, then the environment until the end of the buffer.
    private static func procArgs(of pid: pid_t) -> ProcArgs? {
        var sizeMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        guard sizeMib.withUnsafeMutableBufferPointer({
            sysctl($0.baseAddress, u_int($0.count), &argMax, &argMaxSize, nil, 0)
        }) == 0, argMax > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = Int(argMax)
        let rc = buffer.withUnsafeMutableBytes { bufferBytes in
            mib.withUnsafeMutableBufferPointer { mibBuffer in
                sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count),
                       bufferBytes.baseAddress, &size, nil, 0)
            }
        }
        guard rc == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var chunks: [String] = []
        var current: [UInt8] = []
        for byte in buffer[MemoryLayout<Int32>.size..<size] {
            if byte == 0 {
                if !current.isEmpty {
                    chunks.append(String(decoding: current, as: UTF8.self))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { chunks.append(String(decoding: current, as: UTF8.self)) }

        // chunks[0] is the exec path; the next `argc` entries are argv; the rest is env.
        guard !chunks.isEmpty else { return nil }
        let argvEnd = min(chunks.count, 1 + Int(argc))
        return ProcArgs(
            arguments: Array(chunks[1..<argvEnd]),
            environment: Array(chunks[argvEnd...])
        )
    }
}
