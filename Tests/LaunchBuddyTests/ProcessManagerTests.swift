import Foundation
import XCTest
@testable import LaunchBuddy

/// Drives ProcessManager against real subprocesses: exit codes, signals,
/// user-initiated stops, and process-group cleanup.
///
/// All tests run on the main actor (async XCTest methods) and share
/// ProcessManager.shared, so each leaves the manager stopped before it
/// returns and no test starts while another's process is alive.
@MainActor
final class ProcessManagerTests: XCTestCase {

    private let pm = ProcessManager.shared

    // MARK: - Helpers

    /// Writes `lines` as an executable zsh script in a temp dir.
    private func makeScript(_ lines: String, name: String = "case.sh") throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lbtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name)
        try (lines + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    /// Polls `condition` until true or the timeout, yielding the main actor
    /// between polls so the process's termination handler can run.
    private func waitUntil(timeout: TimeInterval = 15,
                          _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func assertStarted(_ condition: () -> Bool, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await waitUntil { condition() }
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    /// Runs a zsh one-liner and returns its stdout.
    private func shell(_ command: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try? proc.run()
        proc.waitUntilExit()
        return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .newlines)
    }

    // MARK: - Incremental drain

    func test_drain_returns_emitted_text_then_clears() async throws {
        let script = try makeScript("""
        #!/bin/zsh
        echo one
        echo two
        """)
        let before = pm.runID
        pm.start(scriptPath: script)
        XCTAssertNotEqual(pm.runID, before, "each start must bump the run id")
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")

        let drained = pm.drainOutput()
        XCTAssertEqual(drained, "one\ntwo\n",
                       "drain must return everything emitted since the last drain")
        XCTAssertEqual(pm.drainOutput(), "", "drain must clear the buffer")

        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    func test_start_clears_undrained_output() async throws {
        let first = try makeScript("#!/bin/zsh\necho first\n")
        pm.start(scriptPath: first)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")
        _ = pm.drainOutput()

        let second = try makeScript("#!/bin/zsh\necho second\n")
        pm.start(scriptPath: second)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")

        XCTAssertEqual(pm.drainOutput(), "second\n",
                       "a new run must not surface the previous run's output")
        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    func test_clear_output_resets_buffer_but_keeps_run_going() async throws {
        // Python, not zsh: zsh block-buffers output on a pipe, so with a zsh
        // script "before" would only arrive together with "after" at exit and
        // the mid-run state could not be observed. Python prints are unbuffered
        // (PYTHONUNBUFFERED is set by ProcessManager), so "before" really does
        // stream in while the script is still sleeping.
        let script = try makeScript("""
        #!/usr/bin/env python3
        import time
        print("before", flush=True)
        time.sleep(1)
        print("after", flush=True)
        """, name: "case.py")
        pm.start(scriptPath: script)
        await assertStarted({ pm.outputLines.contains("before") },
                           "first output never arrived")

        pm.clearOutput()
        XCTAssertTrue(pm.running, "clearing output must not stop the script")
        XCTAssertTrue(pm.outputLines.isEmpty)

        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")
        XCTAssertEqual(pm.outputLines, ["after"],
                       "output captured after a clear must be kept")
        XCTAssertEqual(pm.drainOutput(), "after\n")

        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    // MARK: - Exit status

    func test_nonzero_exit_code_is_surfaced() async throws {
        let script = try makeScript("""
        #!/bin/zsh
        echo "working"
        exit 3
        """)
        pm.start(scriptPath: script)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")

        let exit = pm.lastExit!
        XCTAssertEqual(exit.reason, .exit)
        XCTAssertEqual(exit.status, 3)
        XCTAssertFalse(exit.isClean)
        XCTAssertEqual(exit.summary, "Script exited (code 3)")

        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    func test_clean_exit_is_marked_clean() async throws {
        let script = try makeScript("""
        #!/bin/zsh
        echo "hello"
        """)
        pm.start(scriptPath: script)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")

        let exit = pm.lastExit!
        XCTAssertEqual(exit.reason, .exit)
        XCTAssertEqual(exit.status, 0)
        XCTAssertTrue(exit.isClean)
        XCTAssertEqual(exit.summary, "Script exited (code 0)")

        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    func test_fatal_signal_is_surfaced() async throws {
        let script = try makeScript("""
        #!/bin/zsh
        kill -KILL $$
        """)
        pm.start(scriptPath: script)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")

        let exit = pm.lastExit!
        XCTAssertEqual(exit.reason, .uncaughtSignal)
        XCTAssertEqual(exit.status, 9)
        XCTAssertEqual(exit.summary, "Script killed by signal 9")

        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    func test_user_stop_suppresses_exit_status() async throws {
        let script = try makeScript("""
        #!/bin/zsh
        sleep 60
        """)
        pm.start(scriptPath: script)
        await assertStarted({ pm.running }, "process never started")

        pm.stop()
        await assertStarted({ !pm.running }, "process never stopped")
        // Give the termination handler a turn, then confirm it recorded
        // nothing for a stop we caused ourselves.
        try? await Task.sleep(for: .seconds(0.5))
        XCTAssertNil(pm.lastExit, "user stop must not surface as an exit status")
    }

    func test_new_start_clears_previous_exit_status() async throws {
        let failing = try makeScript("#!/bin/zsh\nexit 4\n")
        let hanging = try makeScript("#!/bin/zsh\nsleep 30\n")

        pm.start(scriptPath: failing)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")
        XCTAssertNotNil(pm.lastExit)

        pm.start(scriptPath: hanging)
        await assertStarted({ pm.running }, "process never started")
        XCTAssertNil(pm.lastExit, "start must clear the previous run's exit status")

        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    // MARK: - Process-group cleanup

    func test_stop_kills_child_processes_in_the_group() async throws {
        // The script spawns two children in its own process group; stop()
        // must take all of them down, not just the direct child.
        let marker = 321
        let script = try makeScript("""
        #!/bin/zsh
        sleep \(marker) &
        sleep \(marker) &
        wait
        """)
        pm.start(scriptPath: script)
        await assertStarted({ pm.running }, "process never started")

        pm.stop()
        // Wait out the SIGTERM grace period and SIGKILL escalation.
        try? await Task.sleep(for: .seconds(3))

        let survivors = shell("pgrep -f 'sleep \(marker)'")
        XCTAssertTrue(survivors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "child processes survived stop(): \(survivors)")
    }

    // MARK: - Working directory

    func test_default_cwd_is_the_scripts_directory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lbcwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("cwd.sh")
        // pwd -P reports the physical path, so the comparison below is
        // immune to macOS hiding /var behind /private/var.
        try ("#!/bin/zsh\npwd -P").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        pm.start(scriptPath: script.path)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")

        // Compare physical paths on both sides.
        let reported = pm.outputLines.last ?? ""
        let expected = shell("cd \(dir.path) && pwd -P")
        XCTAssertEqual(reported, expected,
                       "default working directory must be the script's own directory")

        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    func test_explicit_working_directory_is_used() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lbcwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A relative file that only resolves from the explicit cwd.
        try "payload".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let script = try makeScript("#!/bin/zsh\ncat note.txt\n")

        pm.start(scriptPath: script, workingDirectory: dir.path)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")

        XCTAssertEqual(pm.outputLines.last, "payload",
                       "relative path must resolve against the configured working directory")
        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    func test_missing_working_directory_fails_cleanly() async throws {
        let script = try makeScript("#!/bin/zsh\ntrue\n")

        pm.start(scriptPath: script, workingDirectory: "/no/such/dir-lbtest")

        XCTAssertFalse(pm.running)
        XCTAssertEqual(pm.launchError, "Working directory not found: /no/such/dir-lbtest")
    }

    // MARK: - Output buffer

    func test_output_buffer_has_no_trailing_empty_line() async throws {
        let script = try makeScript("""
        #!/bin/zsh
        echo "one"
        echo "two"
        """)
        pm.start(scriptPath: script)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")

        XCTAssertEqual(pm.outputLines, ["one", "two"],
                       "a trailing newline must not leave a phantom empty line")
        XCTAssertFalse(pm.outputLines.last?.isEmpty ?? true)
        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    func test_output_buffer_caps_at_max_lines_keeps_suffix() async throws {
        // 1500 lines in; the buffer must keep exactly the last
        // ProcessManager.maxOutputLines of them, dropping the oldest.
        let script = try makeScript("""
        #!/usr/bin/env python3
        import sys
        out = [f"line-{i}" for i in range(1, 1501)]
        sys.stdout.write("\\n".join(out) + "\\n")
        sys.stdout.flush()
        """, name: "cap.py")
        pm.start(scriptPath: script)
        await assertStarted({ pm.lastExit != nil }, "process never reported its exit")
        XCTAssertEqual(pm.outputLines.count, ProcessManager.maxOutputLines)
        XCTAssertEqual(pm.outputLines.first, "line-501")
        XCTAssertEqual(pm.outputLines.last, "line-1500")

        pm.stop()
        _ = await waitUntil { !pm.running }
    }

    // MARK: - End of stream

    func test_eof_delivers_held_partial_utf8_tail() async throws {
        // The stream ends mid-sequence (lone C3 lead after "ok"). The
        // reader's terminal drain must surface that byte as a replacement
        // character instead of losing it.
        let script = try makeScript("""
        #!/usr/bin/env python3
        import sys
        sys.stdout.buffer.write(b"ok\\xC3")
        sys.stdout.buffer.flush()
        """, name: "eoftail.py")
        pm.start(scriptPath: script)
        await assertStarted({ pm.lastExit != nil && pm.outputLines.last == "\u{FFFD}" },
                           "terminal output tail was lost at EOF")
        XCTAssertEqual(pm.outputLines, ["ok", "\u{FFFD}"])
        XCTAssertEqual(pm.drainOutput(), "ok\u{FFFD}")

        pm.stop()
        _ = await waitUntil { !pm.running }
    }

}
