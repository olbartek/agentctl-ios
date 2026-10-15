// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import ConcurrencyExtras

  /// The main serial executor: with it on, every task runs in order on the main thread, which is what makes a
  /// headless run deterministic (CONTRACT.md §6). Turn it on for the duration of a run.
  public enum Deterministic {
    @MainActor
    public static var isEnabled: Bool {
      get { uncheckedUseMainSerialExecutor }
      set { uncheckedUseMainSerialExecutor = newValue }
    }
  }
#endif
