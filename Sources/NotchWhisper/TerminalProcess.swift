import Foundation
import Darwin

/// Finds which command-line program is actually in front inside a terminal.
///
/// Claude Code, Codex, vim, psql and friends are not apps — they are processes
/// running inside Terminal.app or iTerm2, so `NSWorkspace.frontmostApplication`
/// reports the terminal and every CLI tool looks identical to every other.
/// This resolves the tool, so a profile can say "dictating into Claude Code"
/// rather than only "dictating into Terminal".
///
/// Method: one `sysctl(KERN_PROC_ALL)` snapshot, then keep the processes that
///   · descend from the frontmost terminal's pid, and
///   · are the FOREGROUND process group of their tty (`pgid == tpgid`) —
///     the same thing `ps` marks with a `+` in its STAT column.
/// A terminal with several tabs yields one candidate per tab; the caller
/// disambiguates with the focused window's title.
enum TerminalProcess {

    struct Tool: Equatable {
        /// Executable name as the kernel records it (`p_comm`, 16 chars max).
        var name: String
        var pid: pid_t
        /// The controlling tty's device number — one per tab.
        var tty: Int32
        /// A login/interactive shell rather than a program the user launched.
        var isShell: Bool
    }

    /// Command names that mean "just a shell prompt", not a tool.
    static let shellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "login",
    ]

    /// Runtimes that say nothing about which tool is running. When argv[0] is
    /// one of these, the script in argv[1] is the real name — this is how a
    /// Node- or Python-launched CLI avoids being reported as "node".
    static let runtimeNames: Set<String> = [
        "node", "bun", "deno", "npx", "python", "python3", "ruby", "perl",
        "java", "dotnet", "uv", "uvx", "pipx", "env",
    ]

    // MARK: - Snapshot

    private struct Entry {
        var pid: pid_t
        var ppid: pid_t
        var pgid: pid_t
        var tdev: Int32
        var tpgid: pid_t
        var comm: String
    }

    /// Every process on the system. ~1–2 ms; only called when the frontmost app
    /// is a terminal, and only at the start of a dictation.
    private static func snapshot() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between sizing and reading; ask for headroom.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: max(count, 1))
        var actual = size
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &actual, nil, 0) == 0
        }
        guard ok else { return [] }
        let found = actual / MemoryLayout<kinfo_proc>.stride
        return buffer.prefix(found).map { proc in
            var proc = proc
            let comm = withUnsafePointer(to: &proc.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            return Entry(
                pid: proc.kp_proc.p_pid,
                ppid: proc.kp_eproc.e_ppid,
                pgid: proc.kp_eproc.e_pgid,
                tdev: proc.kp_eproc.e_tdev,
                tpgid: proc.kp_eproc.e_tpgid,
                // A login shell's argv starts with "-"; the command is the rest.
                comm: comm.hasPrefix("-") ? String(comm.dropFirst()) : comm
            )
        }
    }

    // MARK: - Command name
    //
    // `p_comm` is the EXECUTABLE's basename, which is not the command's name
    // for anything installed under a versioned path: Claude Code's binary is
    // literally named "2.1.252", so a p_comm-based scan reports a version
    // number as the tool. argv[0] is what the user actually typed.

    /// `KERN_ARGMAX` — the buffer size `KERN_PROCARGS2` demands. Constant for
    /// the life of the boot, so it is read once.
    private static func argMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 0 }
        return Int(value)
    }

    /// argv[0] and argv[1] of `pid`, via `KERN_PROCARGS2`. Same-user processes
    /// only; anything else returns [] and the caller falls back to `p_comm`.
    ///
    /// `buffer` is supplied by the caller and reused across candidates —
    /// KERN_PROCARGS2 refuses anything smaller than KERN_ARGMAX (typically
    /// 1 MB), and allocating that per process on the dictation-start path is
    /// waste for a few hundred bytes of answer.
    private static func arguments(pid: pid_t, buffer: inout [CChar]) -> [String] {
        guard !buffer.isEmpty else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return [] }

        var index = MemoryLayout<Int32>.size          // skip argc
        while index < size, buffer[index] != 0 { index += 1 }   // skip exec path
        while index < size, buffer[index] == 0 { index += 1 }   // skip its padding

        var out: [String] = []
        while index < size, out.count < 2 {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            guard index > start else { break }
            let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
            out.append(String(decoding: bytes, as: UTF8.self))
            index += 1
        }
        return out
    }

    /// The name a user would call this process: argv[0]'s basename, or the
    /// script's basename when argv[0] is a bare runtime. Falls back to `comm`.
    private static func commandName(pid: pid_t, comm: String, buffer: inout [CChar]) -> String {
        let args = arguments(pid: pid, buffer: &buffer)
        guard let first = args.first else { return comm }
        var name = basename(first)
        if runtimeNames.contains(name), args.count > 1 {
            let second = basename(args[1])
            // Skip flags ("node --inspect script.js" is rare but real).
            if !second.hasPrefix("-"), !second.isEmpty { name = second }
        }
        return name.isEmpty ? comm : name
    }

    private static func basename(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.hasPrefix("-") { name = String(name.dropFirst()) }   // login shell
        if name.hasSuffix(".js") || name.hasSuffix(".py") || name.hasSuffix(".rb") {
            name = (name as NSString).deletingPathExtension
        }
        return name
    }

    // MARK: - Resolution

    /// Foreground programs running under `terminalPID`, one per tab, most
    /// recently started first. Empty when the terminal has no live tty (or the
    /// scan failed) — callers treat that as "no CLI tool", never as an error.
    static func foregroundTools(ofTerminal terminalPID: pid_t) -> [Tool] {
        let entries = snapshot()
        guard !entries.isEmpty else { return [] }
        var byPID: [pid_t: Entry] = [:]
        byPID.reserveCapacity(entries.count)
        for entry in entries { byPID[entry.pid] = entry }

        // Best candidate per tty. A foreground process GROUP can hold several
        // processes — Claude Code spawns `caffeinate` into its own group, and
        // picking whichever the kernel listed first reported "caffeinate" as
        // the tool. The group LEADER (pid == pgid) is the job the shell
        // actually launched, so it wins.
        var best: [Int32: (rank: Int, tool: Tool)] = [:]
        var argBuffer = [CChar](repeating: 0, count: argMax())
        for entry in entries {
            // Foreground process group of a real tty — what `ps` marks "+".
            guard entry.tdev != -1, entry.tpgid > 0, entry.pgid == entry.tpgid else { continue }
            guard descends(entry, from: terminalPID, in: byPID) else { continue }
            let name = commandName(pid: entry.pid, comm: entry.comm, buffer: &argBuffer)
            let isShell = shellNames.contains(name)
            let isLeader = entry.pid == entry.pgid
            // A NON-shell always beats a shell on the same tty. Job control is
            // off in a non-interactive shell, so a program it runs shares the
            // shell's process group and is not the leader — ranking by
            // leadership alone reported "bash" for a window running `head`.
            let rank: Int
            switch (isShell, isLeader) {
            case (false, true):  rank = 0     // the program the user started
            case (false, false): rank = 1     // a program under a script/wrapper
            case (true, true):   rank = 2     // a bare shell prompt
            case (true, false):  rank = 3
            }
            let tool = Tool(name: name, pid: entry.pid, tty: entry.tdev, isShell: isShell)
            if let existing = best[entry.tdev], existing.rank <= rank { continue }
            best[entry.tdev] = (rank, tool)
        }
        return best.values.map(\.tool).sorted { $0.pid > $1.pid }
    }

    /// Walks the parent chain up to `terminalPID`. Bounded — a corrupt or
    /// racing snapshot must not spin.
    private static func descends(_ entry: Entry, from terminalPID: pid_t,
                                 in byPID: [pid_t: Entry]) -> Bool {
        var current = entry
        for _ in 0..<24 {
            if current.pid == terminalPID || current.ppid == terminalPID { return true }
            guard current.ppid > 1, let parent = byPID[current.ppid] else { return false }
            current = parent
        }
        return false
    }

    /// The tool the user is looking at: the one named in the focused window's
    /// title when several tabs are busy, otherwise the only candidate.
    /// Prefers a real program over a bare shell.
    static func focusedTool(terminalPID: pid_t, windowTitle: String?) -> Tool? {
        let tools = foregroundTools(ofTerminal: terminalPID)
        guard !tools.isEmpty else { return nil }
        if tools.count == 1 { return tools[0] }
        if let title = windowTitle?.lowercased() {
            // Terminal.app and iTerm2 put the running command in the title.
            // A program wins over a shell that happens to also be named there.
            let named = tools.filter { title.contains($0.name.lowercased()) }
            if let tool = named.first(where: { !$0.isShell }) ?? named.first { return tool }
        }
        return tools.first { !$0.isShell } ?? tools.first
    }
}
