import Cocoa

class CommandRunner {
  /// Cached environment captured from the user's interactive shell.
  /// Populated lazily on first `run()` so it doesn't slow app launch.
  /// `nil` means "not captured yet"; an empty dict means "capture failed, use inherited".
  private static var cachedUserEnv: [String: String]?
  private static let cacheQueue = DispatchQueue(label: "CommandRunner.envCache")

  static func run(_ command: String) {
    let task = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()

    task.standardOutput = pipe
    task.standardError = errorPipe
    // Non-interactive shell: the user's environment is supplied via `task.environment`
    // (captured from an interactive shell once, see `userShellEnvironment()`).
    // This keeps each run fast and prompt-noise-free while still resolving commands
    // the user has on PATH in their Terminal (brew, mise/asdf shims, etc.).
    task.launchPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
    task.arguments = ["-c", command]
    task.environment = userShellEnvironment()
    task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

    do {
      try task.run()
      task.waitUntilExit()

      if task.terminationStatus != 0 {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let error = String(data: errorData, encoding: .utf8) ?? ""
        let output = String(data: outputData, encoding: .utf8) ?? ""

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Command failed with exit code \(task.terminationStatus)"
        alert.informativeText = [error, output].joined(separator: "\n").trimmingCharacters(
          in: .whitespacesAndNewlines)
        alert.runModal()
      }
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "Failed to run command"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }

  // MARK: - Shell environment capture

  /// Returns the environment to use for running commands: the app's inherited
  /// environment merged with the user's interactive-shell environment (the latter
  /// wins on conflict, e.g. PATH).
  private static func userShellEnvironment() -> [String: String] {
    let inherited = ProcessInfo.processInfo.environment
    let captured = capturedUserShellEnvironment()
    return inherited.merging(captured) { _, new in new }
  }

  /// Captures (once) the user's interactive zsh environment by running
  /// `zsh -i -c 'env'` and parsing the output. Falls back to an empty dict
  /// (so the caller uses the inherited environment) on failure or timeout.
  ///
  /// Note: this captures environment *variables* only — shell functions and
  /// aliases defined in `.zshrc` are not available to commands. For Leader Key's
  /// "command" actions (external binaries like `brew`, `node`, `git`, …) this is
  /// sufficient, since their availability is a function of PATH.
  private static func capturedUserShellEnvironment() -> [String: String] {
    if let cached = cachedUserEnv { return cached }

    var captured = captureUserShellEnvironmentBlocking()
    if captured == nil {
      // Capture failed (timeout, broken .zshrc, …). Cache an empty dict so we
      // don't retry the slow capture on every command.
      captured = [:]
    }

    cacheQueue.sync { cachedUserEnv = captured }
    return captured!
  }

  /// Runs the user's shell interactively once to dump its environment.
  /// Returns `nil` on failure or timeout (default 5s).
  private static func captureUserShellEnvironmentBlocking(timeout: TimeInterval = 5) -> [String: String]? {
    let inherited = ProcessInfo.processInfo.environment
    let shell = inherited["SHELL"] ?? "/bin/zsh"

    let task = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()
    task.standardOutput = pipe
    task.standardError = errorPipe
    task.launchPath = shell
    // Interactive + login: sources .zprofile (brew shellenv), .zshrc (mise activate),
    // and ~/.config/zsh/*.zsh, mirroring what the user gets in Terminal.
    task.arguments = ["-i", "-l", "-c", "env"]
    // Avoid recursing into a TTY-aware prompt; keep it minimal.
    task.environment = inherited.filter { key, _ in key != "TERM" }

    do {
      try task.run()

      // Enforce a timeout so a blocking .zshrc (e.g. a `read` prompt) can't hang us.
      let deadline = DispatchTime.now() + timeout
      while task.isRunning && DispatchTime.now() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if task.isRunning {
        task.terminate()
        return nil
      }

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      guard let output = String(data: data, encoding: .utf8) else { return nil }
      return parseEnvOutput(output)
    } catch {
      return nil
    }
  }

  /// Parses the output of `env` into a dictionary. Lines are split on the first
  /// `=`. Lines without `=` are ignored. Pure function — safe to unit test.
  static func parseEnvOutput(_ output: String) -> [String: String] {
    var env: [String: String] = [:]
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let eqIndex = line.firstIndex(of: "=") else { continue }
      let key = String(line[line.startIndex..<eqIndex])
      let value = String(line[line.index(after: eqIndex)..<line.endIndex])
      env[key] = value
    }
    return env
  }

  /// Resets the cached environment. Used by tests.
  static func _resetCacheForTesting() {
    cacheQueue.sync { cachedUserEnv = nil }
  }
}
