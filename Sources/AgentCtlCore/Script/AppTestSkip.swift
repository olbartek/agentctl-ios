import Foundation

/// A scenario's request to be left out of `app test`, the run through the app on a simulator.
///
/// A few scenarios hold headlessly but not in a running app: a first `expect` on the launch's own calls (which
/// `app launch` has already made), or a date that is in the future only against the headless fixed date. A comment
/// line says so, with a reason, anywhere in the file:
///
/// ```
/// # app-test: skip the launch's calls are made before the script starts
/// ```
///
/// `# appctl-sim: skip <reason>` is accepted as well: the marker's name in the scripts that ran scenarios this way
/// before `app test` existed.
public enum AppTestSkip {
  static let markers = ["app-test:", "appctl-sim:"]

  /// The reason `source` gives for skipping it in the app, or `nil` if it gives none. A marker without a reason
  /// still skips, with "no reason given".
  public static func reason(in source: String) -> String? {
    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("#") else { continue }
      let comment = line.dropFirst().trimmingCharacters(in: .whitespaces)
      for marker in markers where comment.hasPrefix(marker) {
        let directive = comment.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard directive == "skip" || directive.hasPrefix("skip ") else { continue }
        let reason = directive.dropFirst("skip".count).trimmingCharacters(in: .whitespaces)
        return reason.isEmpty ? "no reason given" : reason
      }
    }
    return nil
  }
}
