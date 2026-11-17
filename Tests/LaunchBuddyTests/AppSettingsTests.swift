import XCTest
@testable import LaunchBuddy

/// The Settings script-path field flags only genuinely missing files; an
/// unset path is fine, and an existing-but-not-executable file is fine
/// because ProcessManager.start() chmods it before launching.
final class AppSettingsTests: XCTestCase {
    func test_unset_path_has_no_problem() {
        XCTAssertNil(AppSettings.scriptPathProblem(""))
    }

    func test_existing_path_has_no_problem() {
        XCTAssertNil(AppSettings.scriptPathProblem("/bin/zsh"))
    }

    func test_missing_path_is_flagged() {
        XCTAssertEqual(AppSettings.scriptPathProblem("/no/such/script-lbtest"),
                       "File not found: /no/such/script-lbtest")
    }
}
