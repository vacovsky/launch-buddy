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
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
}
