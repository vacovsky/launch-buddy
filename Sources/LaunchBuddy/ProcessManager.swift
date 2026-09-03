import Foundation
import Darwin

/// Owns the spawned script process and its captured output.
///
/// All state lives on the main actor: the UI (menu bar, output window) reads
/// it, and the pipe/termination callbacks hop here before mutating it.
@MainActor @Observable
final class ProcessManager {
    static let shared = ProcessManager()

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var outputPipe: Pipe?
    @ObservationIgnored private var processGroupID: pid_t = 0
    /// Bumped on every start; lets in-flight output chunks from a previous run
    /// drop out instead of contaminating the new run's buffer.
    @ObservationIgnored private var generation: UInt64 = 0

    var running: Bool = false
    var launchError: String?
    var outputLines: [String] = []

    private static let maxOutputLines = 1000
    private static let stdbufPath = "/usr/bin/stdbuf"

    private init() {}

    // MARK: - Starting

    func start(scriptPath: String) {
        guard !running else { return }

        launchError = nil
        outputLines = []

        guard !scriptPath.isEmpty else {
            launchError = "No script path configured"
            return
        }

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            launchError = "File not found: \(scriptPath)"
            return
        }

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
            let perms = (attrs[.posixPermissions] as? UInt) ?? 0
            if perms & 0o111 == 0 {
                try FileManager.default.setAttributes([.posixPermissions: perms | 0o755], ofItemAtPath: scriptPath)
            }
        } catch {
            launchError = "Permission error: \(error.localizedDescription)"
            return
        }

        let proc = Process()
        let pipe = Pipe()

        let isShellScript = ["sh", "bash", "zsh", "csh", "ksh", "fish"]
            .contains(URL(fileURLWithPath: scriptPath).pathExtension.lowercased())
        // stdbuf is only present on newer macOS; fall back to a direct exec
        // so launching keeps working on older systems.
        let hasStdbuf = FileManager.default.isExecutableFile(atPath: Self.stdbufPath)

        // Keep common interpreters unbuffered so output arrives in real time.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        proc.environment = env

        if hasStdbuf {
            proc.executableURL = URL(fileURLWithPath: Self.stdbufPath)
            proc.arguments = isShellScript
                ? ["-o0", "-e0", "/bin/zsh", scriptPath]
                : ["-o0", "-e0", scriptPath]
        } else {
            proc.executableURL = URL(fileURLWithPath: isShellScript ? "/bin/zsh" : scriptPath)
            proc.arguments = isShellScript ? [scriptPath] : []
        }

        proc.standardOutput = pipe
        proc.standardError = pipe

        let decoder = UTF8StreamDecoder()
        generation &+= 1
        let gen = generation

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let data = try? handle.read(upToCount: 65536),
                  !data.isEmpty,
                  let text = decoder.decode(data) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                var lines = self.outputLines
                lines.append(contentsOf: text.components(separatedBy: .newlines))
                if lines.count > Self.maxOutputLines {
                    lines = Array(lines.suffix(Self.maxOutputLines))
                }
                self.outputLines = lines
            }
        }

        proc.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                // Only clear state if this is still the live process, so a late
                // handler from an older run cannot clobber a newer start().
                guard let self, self.process === proc else { return }
                self.running = false
                self.process = nil
                self.outputPipe = nil
                self.processGroupID = 0
            }
        }

        do {
            try proc.run()
            // Put the child in its own process group so stop/quit can kill the
            // whole tree. (pid, pid) is the portable form. The child may have
            // exec'd before we get here, which makes setpgid fail (EACCES);
            // fall back to the group the spawn actually put it in — unless that
            // is our own group, which must never be a kill target.
            if setpgid(proc.processIdentifier, proc.processIdentifier) == 0 {
                self.processGroupID = proc.processIdentifier
            } else {
                let actual = getpgid(proc.processIdentifier)
                self.processGroupID = (actual > 0 && actual != getpgid(0)) ? actual : 0
            }
            self.process = proc
            self.outputPipe = pipe
            self.running = true
            if self.processGroupID > 0 {
                ScriptSignalGuard.groupPgid = self.processGroupID
            }
        } catch {
            let nsError = error as NSError
            launchError = "Failed to launch: \(nsError.localizedDescription) (code: \(nsError.code))"
        }
    }

    // MARK: - Stopping

    /// Graceful stop: SIGTERM to the process group, SIGKILL after a short grace
    /// period for anything that survives.
    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        let pgid = processGroupID
        let proc = process

        process = nil
        outputPipe = nil
        processGroupID = 0
        running = false

        guard let proc = proc else { return }

        Task.detached {
            if pgid > 0 {
                kill(-pgid, SIGTERM)
            } else {
                proc.terminate()
            }

            try? await Task.sleep(for: .seconds(2))

            if pgid > 0 {
                // The direct child may be gone while processes it spawned are
                // still alive in the group; SIGKILL the rest. A no-op (ESRCH)
                // if the whole group already exited.
                kill(-pgid, SIGKILL)
            } else if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            // Escalation is complete; the group is no longer a quit-time target.
            if ScriptSignalGuard.groupPgid == pgid {
                ScriptSignalGuard.groupPgid = 0
            }
        }
    }

    /// Synchronous kill for app termination, when there is no time for the
    /// TERM→KILL escalation.
    func killSync() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        let pgid = processGroupID
        let proc = process

        process = nil
        outputPipe = nil
        processGroupID = 0
        running = false

        if pgid > 0 {
            kill(-pgid, SIGKILL)
        } else if let proc {
            kill(proc.processIdentifier, SIGKILL)
        }
        ScriptSignalGuard.groupPgid = 0
    }
}

/// Catches SIGTERM/SIGINT so the script's process group is killed even when
/// AppKit exits without running `applicationShouldTerminate` (logout, shutdown,
/// `kill`). The handler is async-signal-safe: it only reads a global and calls
/// `kill` and `exit`.
enum ScriptSignalGuard {
    /// Process group of the running script, or 0 if none. Kept in sync by
    /// ProcessManager; read best-effort from the signal handler.
    /// Deliberately not isolation-checked: the signal handler reads this from
    /// an arbitrary thread; a stale value can at worst target an already-dead
    /// group.
    nonisolated(unsafe) static var groupPgid: pid_t = 0

    static func install() {
        // signal() on Darwin keeps the handler installed across deliveries
        // (no reset to SIG_DFL), which is all the guard needs: it exits.
        signal(SIGTERM, scriptSignalHandler)
        signal(SIGINT, scriptSignalHandler)
    }
}

private func scriptSignalHandler(_ signal: Int32) {
    let pgid = ScriptSignalGuard.groupPgid
    if pgid > 0 {
        kill(-pgid, SIGKILL)
    }
    exit(0)
}

/// Decodes an unbounded byte stream as UTF-8, holding back a trailing partial
/// multi-byte sequence until the next chunk completes it, so code points split
/// across pipe reads are never corrupted. Callers must be serial.
/// - Note: touched only from the (serial) pipe readability-handler queue, so
/// it is safe to share across the handler's dispatches.
private final class UTF8StreamDecoder: @unchecked Sendable {
    private var pending = Data()

    /// Appends `data` to the buffer and returns the newly decodable text, or
    /// nil if nothing new was decodable.
    func decode(_ data: Data) -> String? {
        pending.append(data)

        // A buffer that fails to decode does so only because of (a) an
        // incomplete sequence at the tail (at most 3 held-back bytes) or
        // (b) genuinely invalid bytes. For (a): drop tail bytes until the
        // prefix decodes.
        for drop in 0...3 {
            let end = pending.index(pending.endIndex, offsetBy: -min(drop, pending.count))
            guard end > pending.startIndex else { continue }
            if let text = String(data: pending.prefix(upTo: end), encoding: .utf8) {
                if end == pending.endIndex {
                    pending.removeAll(keepingCapacity: true)
                } else {
                    pending = Data(pending.suffix(from: end))
                }
                return text
            }
        }

        // (b): non-UTF-8 output — decode with replacement characters so
        // nothing is lost.
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return text.isEmpty ? nil : text
    }
}
