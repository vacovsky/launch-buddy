import Foundation
import AppKit
import UserNotifications
import Darwin

/// Owns the spawned script process and its captured output.
///
/// All state lives on the main actor: the UI (menu bar, output window) reads
/// it, and the pipe/termination callbacks hop here before mutating it.
@MainActor @Observable
final class ProcessManager {
    static let shared = ProcessManager()

    @ObservationIgnored private var process: Process?
    /// Drains the output pipe; kept so stop/kill/termination can cancel it,
    /// which also closes the pipe's read end.
    @ObservationIgnored private var outputReadSource: DispatchSourceRead?
    @ObservationIgnored private var processGroupID: pid_t = 0
    /// Bumped on every start; observable so the output window can detect a
    /// new run. In-flight chunks from a previous run compare against it and
    /// drop out instead of contaminating the new run's buffer.
    private(set) var runID: UInt64 = 0
    /// True between a user-initiated stop/kill and the next start; suppresses
    /// the exit-status UI for stops we caused ourselves.
    @ObservationIgnored private var userStopped = false
    /// Output text appended since the last `drainOutput()`; the output
    /// window consumes it so it can append only the delta to the text view
    /// instead of re-laying out the whole buffer on every chunk.
    @ObservationIgnored private var pendingOutput = ""
    /// Parameters of the live run; the watchdog relaunches with them when
    /// the script exits on its own.
    @ObservationIgnored private var lastStart: (scriptPath: String,
                                                workingDirectory: String,
                                                arguments: String,
                                                environment: String)?

    /// When the last unexpected-exit notification was posted; combined with
    /// the cooldown below so a crash-looping script (especially under the
    /// watchdog) cannot flood the Notification Center.
    @ObservationIgnored private var lastExitNotificationAt: Date?

    var running: Bool = false
    var launchError: String?
    var outputLines: [String] = []
    /// Info about the last run that ended on its own. nil while running,
    /// after a user-initiated stop, and after a new start.
    var lastExit: ExitInfo?

    /// Lines kept in `outputLines` (and mirrored by the output window).
    static let maxOutputLines = 1000
    private static let stdbufPath = "/usr/bin/stdbuf"
    /// Cap for undrained output text, so a chatty script cannot grow it
    /// without bound while the output window is closed; the window
    /// re-initializes from `outputLines` when it opens anyway.
    private static let maxPendingOutputChars = 1_000_000
    private static let exitNotificationCooldown: TimeInterval = 60

    /// Returns the text emitted since the last call and marks it drained.
    /// The output window consumes this so it appends only the delta to the
    /// text view instead of re-laying out the whole buffer.
    func drainOutput() -> String {
        defer { pendingOutput = "" }
        return pendingOutput
    }

    /// Clears captured output for the current run; the script keeps running
    /// and new output is captured into the fresh buffer.
    func clearOutput() {
        outputLines = []
        pendingOutput = ""
    }

    /// Banner + system beep for an exit that was neither clean nor
    /// user-caused, so an unattended crash is not silently swallowed.
    /// Only active when running as an installed .app (the test runner has
    /// no notification service), and rate-limited so a crash loop cannot
    /// flood the Notification Center.
    private func notifyUnexpectedExit(_ info: ExitInfo) {
        guard Bundle.main.bundleURL.pathExtension == ".app" else { return }
        let now = Date()
        if let last = lastExitNotificationAt,
           now.timeIntervalSince(last) < Self.exitNotificationCooldown {
            return
        }
        lastExitNotificationAt = now
        NSSound.beep()
        let content = UNMutableNotificationContent()
        content.title = "Launch Buddy"
        content.body = info.summary
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Folds newly decoded output into the buffers. Runs on the main actor;
    /// the pipe reader's queue hops here per chunk. `gen` drops late chunks
    /// from a superseded run.
    private func ingest(_ text: String, gen: UInt64) {
        guard runID == gen else { return }
        pendingOutput += text
        if pendingOutput.count > Self.maxPendingOutputChars {
            pendingOutput = ""
        }
        var lines = outputLines
        // "abc\n" splits into ["abc", ""]; drop the phantom empty element so
        // the buffer does not end with a ghost line.
        var newLines = text.components(separatedBy: .newlines)
        if newLines.last == "" {
            newLines.removeLast()
        }
        lines.append(contentsOf: newLines)
        if lines.count > Self.maxOutputLines {
            lines = Array(lines.suffix(Self.maxOutputLines))
        }
        outputLines = lines
    }

    private init() {}
    func start(scriptPath: String,
              workingDirectory: String = "",
              arguments: String = "",
              environment: String = "") {
        guard !running else { return }

        launchError = nil
        outputLines = []
        lastExit = nil
        userStopped = false
        pendingOutput = ""

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

        // Empty working directory means "the script's own directory" — the
        // most common expectation for relative paths, and unlike the bundle's
        // launch cwd (/) it actually exists.
        var isDirectory: ObjCBool = false
        let cwdPath = workingDirectory.isEmpty
            ? (URL(fileURLWithPath: scriptPath).deletingLastPathComponent())
            : URL(fileURLWithPath: workingDirectory)
        if !workingDirectory.isEmpty,
           !FileManager.default.fileExists(atPath: cwdPath.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            launchError = "Working directory not found: \(workingDirectory)"
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
        // User-configured variables merge over the defaults, so they can
        // override them (e.g. PYTHONUNBUFFERED=0).
        for (key, value) in Self.parseEnvironment(environment) {
            env[key] = value
        }
        proc.environment = env
        proc.currentDirectoryURL = cwdPath
        let args = Self.tokenizeArguments(arguments)

        if hasStdbuf {
            proc.executableURL = URL(fileURLWithPath: Self.stdbufPath)
            // Script arguments follow the script path: zsh hands them to the
            // shell script as $@, interpreters see them in argv.
            proc.arguments = (isShellScript
                ? ["-o0", "-e0", "/bin/zsh", scriptPath]
                : ["-o0", "-e0", scriptPath]) + args
        } else {
            proc.executableURL = URL(fileURLWithPath: isShellScript ? "/bin/zsh" : scriptPath)
            proc.arguments = (isShellScript ? [scriptPath] : []) + args
        }

        proc.standardOutput = pipe
        proc.standardError = pipe

        let decoder = UTF8StreamDecoder()
        runID &+= 1
        let gen = runID

        proc.terminationHandler = { [weak self] p in
            // Read the exit details on the handler's thread, where they are
            // guaranteed available, and hand them to the main actor.
            let reason = p.terminationReason
            let status = p.terminationStatus
            Task { @MainActor [weak self] in
                // Only clear state if this is still the live process, so a late
                // handler from an older run cannot clobber a newer start().
                guard let self, self.process === p else { return }
                self.outputReadSource?.cancel()
                self.outputReadSource = nil
                self.running = false
                self.process = nil
                self.processGroupID = 0
                if !self.userStopped {
                    let info = ExitInfo(reason: reason, status: status)
                    self.lastExit = info
                    if !info.isClean {
                        self.notifyUnexpectedExit(info)
                    }
                    // Watchdog: relaunch with the same parameters when the
                    // script exits on its own and the user opted in. A
                    // user stop (userStopped) or a disabled watchdog must
                    // not respawn the run.
                    if AppSettings().restartOnExit,
                       let last = self.lastStart {
                        self.start(scriptPath: last.scriptPath,
                                   workingDirectory: last.workingDirectory,
                                   arguments: last.arguments,
                                   environment: last.environment)
                    }
                }
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
            self.lastStart = (scriptPath, workingDirectory, arguments, environment)
            self.running = true
            if self.processGroupID > 0 {
                ScriptSignalGuard.groupPgid = self.processGroupID
            }

            // Recent macOS only reports the pipe as readable at EOF: writes
            // made while the child is alive surface as one burst when it
            // exits. A DispatchSourceRead on a background queue reads the
            // pipe directly, so every write arrives as it happens.
            let readHandle = pipe.fileHandleForReading
            let fd = readHandle.fileDescriptor
            let source = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: DispatchQueue(label: "launchbuddy.script-output"))
            source.setEventHandler { [weak self] in
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
                defer { buf.deallocate() }
                var n = read(fd, buf, 65536)
                while n < 0 && errno == EINTR {
                    n = read(fd, buf, 65536)
                }
                if n <= 0 {
                    // EOF (or read error): the cancel handler drains what
                    // remains and closes the read end.
                    source.cancel()
                    return
                }
                guard let text = decoder.decode(Data(UnsafeBufferPointer(start: buf, count: n))),
                      !text.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.ingest(text, gen: gen)
                }
            }
            // The cancel handler runs on the source's queue after any
            // in-flight event handler, so this drain cannot race a read.
            // Collecting whatever is still in the pipe plus the decoder's
            // held-back partial tail here means terminal output survives
            // however the run ends: EOF, stop(), or killSync().
            source.setCancelHandler { [weak self] in
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
                defer { buf.deallocate() }
                var n = read(fd, buf, 65536)
                while n > 0 {
                    if let text = decoder.decode(Data(UnsafeBufferPointer(start: buf, count: n))),
                       !text.isEmpty {
                        Task { @MainActor [weak self] in
                            self?.ingest(text, gen: gen)
                        }
                    }
                    n = read(fd, buf, 65536)
                    while n < 0 && errno == EINTR {
                        n = read(fd, buf, 65536)
                    }
                }
                // The stream is over: surface the decoder's held-back
                // partial tail (replacement characters) so a final partial
                // character is not lost.
                if let tail = decoder.flush() {
                    Task { @MainActor [weak self] in
                        self?.ingest(tail, gen: gen)
                    }
                }
                // closeFile() releases ownership so the handle's deinit
                // does not close a (possibly reused) descriptor twice.
                readHandle.closeFile()
            }
            self.outputReadSource = source
            source.activate()
        } catch {
            let nsError = error as NSError
            // The launch failed before the reader source existed, so release
            // the pipe ends ourselves; they would otherwise leak.
            pipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
            launchError = "Failed to launch: \(nsError.localizedDescription) (code: \(nsError.code))"
        }
    }

    // MARK: - Stopping

    /// Graceful stop: SIGTERM to the process group, SIGKILL after a short grace
    /// period for anything that survives.
    func stop() {
        outputReadSource?.cancel()

        let pgid = processGroupID
        let proc = process

        process = nil
        outputReadSource = nil
        processGroupID = 0
        running = false
        userStopped = true

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
        outputReadSource?.cancel()

        let pgid = processGroupID
        let proc = process

        process = nil
        outputReadSource = nil
        processGroupID = 0
        running = false
        userStopped = true

        if pgid > 0 {
            kill(-pgid, SIGKILL)
        } else if let proc {
            kill(proc.processIdentifier, SIGKILL)
        }
        ScriptSignalGuard.groupPgid = 0
    }

    // MARK: - Argument / environment parsing

    /// Splits a whitespace-separated argument string into discrete arguments,
    /// honoring double quotes so `one "two words" three` yields
    /// `["one", "two words", "three"]`. An unbalanced quote ends the quoted
    /// region at end of input rather than swallowing the remainder.
    static func tokenizeArguments(_ input: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false

        for scalar in input.unicodeScalars {
            if scalar == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if scalar.properties.isWhitespace && !inQuotes {
                if hasToken || !current.isEmpty {
                    args.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.unicodeScalars.append(scalar)
                hasToken = true
            }
        }
        if hasToken || !current.isEmpty {
            args.append(current)
        }
        return args
    }

    /// Parses `KEY=VALUE` environment lines. Blank lines are skipped; a line
    /// without `=` is ignored. The first `=` is the delimiter so values may
    /// contain further `=`. Returns key/value pairs in input order.
    static func parseEnvironment(_ input: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        for line in input.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let eq = trimmed.firstIndex(of: "="),
                  trimmed.index(trimmed.startIndex, offsetBy: 0) < eq
            else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
            guard !key.isEmpty else { continue }
            pairs.append((key, value))
        }
        return pairs
    }
}

/// Why a script run ended, for surfacing in the UI.
struct ExitInfo: Equatable {
    let reason: Process.TerminationReason
    let status: Int32

    /// True when the script ran to completion with exit code 0.
    var isClean: Bool { reason == .exit && status == 0 }

    var summary: String {
        reason == .exit
            ? "Script exited (code \(status))"
            : "Script killed by signal \(status)"
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
/// - Note: touched only from the (serial) pipe reader source's queue, so it
/// is safe to share across the reader's dispatches.
final class UTF8StreamDecoder: @unchecked Sendable {
    private var pending = Data()

    /// Appends `data` to the buffer and returns the newly decodable text, or
    /// nil if nothing new was decodable.
    func decode(_ data: Data) -> String? {
        pending.append(data)
        guard !pending.isEmpty else { return nil }

        if let text = String(data: pending, encoding: .utf8) {
            pending.removeAll(keepingCapacity: true)
            return text
        }

        // The buffer is not valid UTF-8. If it ends with a partial
        // multi-byte sequence, hold those tail bytes for the next chunk;
        // everything before them is decoded now (invalid bytes in the
        // prefix become replacement characters).
        if let tail = partialTailLength(of: pending) {
            let end = pending.index(pending.endIndex, offsetBy: -tail)
            let prefix = pending.prefix(upTo: end)
            pending = Data(pending.suffix(from: end))
            guard !prefix.isEmpty else { return nil }
            return String(decoding: prefix, as: UTF8.self)
        }

        // No held-back tail: the buffer is invalid as a whole.
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return text
    }

    /// Length (1–3) of the trailing bytes of `buffer` that form a valid
    /// prefix of a multi-byte sequence still awaiting continuation bytes,
    /// or nil when the buffer does not end in one. Only lead bytes can
    /// start a held-back sequence; a bare continuation byte is invalid,
    /// not partial.
    private func partialTailLength(of buffer: Data) -> Int? {
        let bytes = [UInt8](buffer)
        for back in 0..<min(3, bytes.count) {
            let i = bytes.count - 1 - back
            let required: Int
            switch bytes[i] {
            case 0xC2...0xDF: required = 2
            case 0xE0...0xEF: required = 3
            case 0xF0...0xF4: required = 4
            default: continue
            }
            let have = bytes.count - i
            guard have < required,
                  bytes[(i + 1)...].allSatisfy({ $0 & 0xC0 == 0x80 })
            else { continue }
            return have
        }
        return nil
    }

    /// Decodes any held-back partial sequence (with replacement characters)
    /// and empties the buffer. Call once when the stream ends so the tail
    /// bytes are not lost.
    func flush() -> String? {
        defer { pending.removeAll(keepingCapacity: true) }
        guard !pending.isEmpty else { return nil }
        return String(decoding: pending, as: UTF8.self)
    }
}
