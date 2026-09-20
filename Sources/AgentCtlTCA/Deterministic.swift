import ComposableArchitecture

/// Deterministic scheduling for headless runs: every task, including actor jobs, runs in order on the main
/// serial executor. `appctl` enables it for the whole process.
public enum Deterministic {
  @MainActor
  public static var isEnabled: Bool {
    get { uncheckedUseMainSerialExecutor }
    set { uncheckedUseMainSerialExecutor = newValue }
  }
}

extension ScriptRunner {
  /// `customDump` of the root state, as printed by `appctl state`.
  public var stateDump: String {
    var output = ""
    customDump(state, to: &output)
    return output
  }
}
