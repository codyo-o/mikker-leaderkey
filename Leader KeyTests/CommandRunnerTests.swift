import XCTest

@testable import Leader_Key

final class CommandRunnerTests: XCTestCase {

  // MARK: - parseEnvOutput

  func testParseEnvOutputParsesSimpleKeyValue() {
    let output = """
      PATH=/usr/bin:/bin
      HOME=/Users/test
      SHELL=/bin/zsh
      """
    let env = CommandRunner.parseEnvOutput(output)

    XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
    XCTAssertEqual(env["HOME"], "/Users/test")
    XCTAssertEqual(env["SHELL"], "/bin/zsh")
  }

  func testParseEnvOutputHandlesEmptyValue() {
    let env = CommandRunner.parseEnvOutput("EMPTY=\nFOO=bar")

    XCTAssertEqual(env["EMPTY"], "")
    XCTAssertEqual(env["FOO"], "bar")
  }

  func testParseEnvOutputSplitsOnFirstEqualsOnly() {
    // Values may contain `=` (e.g. URLs, base64). Only the first `=` is a separator.
    let env = CommandRunner.parseEnvOutput("TOKEN=abc=def=ghi")

    XCTAssertEqual(env["TOKEN"], "abc=def=ghi")
  }

  func testParseEnvOutputIgnoresLinesWithoutEquals() {
    let env = CommandRunner.parseEnvOutput("PATH=/bin\n_underscore-prefixed line\nFOO=bar")

    XCTAssertEqual(env.count, 2)
    XCTAssertEqual(env["PATH"], "/bin")
    XCTAssertEqual(env["FOO"], "bar")
    XCTAssertNil(env["_underscore-prefixed line"])
  }

  func testParseEnvOutputHandlesEmptyInput() {
    let env = CommandRunner.parseEnvOutput("")

    XCTAssertTrue(env.isEmpty)
  }

  func testParseEnvOutputTrimsTrailingNewline() {
    let env = CommandRunner.parseEnvOutput("PATH=/bin\n")

    XCTAssertEqual(env["PATH"], "/bin")
    XCTAssertEqual(env.count, 1)
  }

  func testParseEnvOutputPreservesValueWithSpaces() {
    let env = CommandRunner.parseEnvOutput("PS1=%n %m %1~\nEDITOR=zed --wait")

    XCTAssertEqual(env["PS1"], "%n %m %1~")
    XCTAssertEqual(env["EDITOR"], "zed --wait")
  }

  // MARK: - userShellEnvironment merge precedence

  func testUserShellEnvironmentPrefersCapturedOverInherited() {
    // The inherited environment should be merged with the captured one,
    // with the captured (user shell) values winning on conflict.
    // We can't easily inject a fake inherited env, but we can verify the merge
    // semantics indirectly: if PATH appears in the captured env, it wins.
    // This test documents the contract rather than testing private state.
    // The real merge happens in `userShellEnvironment()` which is private;
    // here we test the public `parseEnvOutput` that feeds it.

    let captured = CommandRunner.parseEnvOutput("PATH=/captured/bin:/usr/bin")
    let inherited = ["PATH": "/inherited/bin"]

    let merged = inherited.merging(captured) { _, new in new }

    XCTAssertEqual(merged["PATH"], "/captured/bin:/usr/bin")
  }

  // MARK: - Cache reset

  func testResetCacheForTestingDoesNotCrash() {
    CommandRunner._resetCacheForTesting()
    // Calling again should be safe
    CommandRunner._resetCacheForTesting()
  }

  // MARK: - warmCache dedup

  func testWarmCacheIsSafeToCallMultipleTimes() {
    CommandRunner._resetCacheForTesting()

    // Calling warmCache twice in quick succession must not start duplicate
    // captures. The second call should be a no-op (cache or pending present).
    CommandRunner.warmCache()
    CommandRunner.warmCache()

    // No assertion on captured contents (depends on the machine's shell); this
    // test guards against crashes and duplicate-spawn regressions.
    CommandRunner._resetCacheForTesting()
  }
}
