#if DEBUG && canImport(UIKit)
  import OSLog
  import UIKit

  /// Whether UIKit is between screens: a navigation push or pop, or a presentation or dismissal, still animating.
  ///
  /// SwiftUI's `NavigationStack` and sheets run on view controllers, so their transitions show up here. A command sent
  /// mid-transition can be lost (a push that lands during a pop's animation may never be shown), so a live step settles
  /// only once no transition is in flight.
  ///
  /// Only an animated transition of a controller on screen counts. A controller's `isMovingToParent` and the like can
  /// stay set with nothing animating, when it was pushed onto a stack that was not in a window yet (a root swap whose
  /// new root pushes at once); a transition coordinator exists only while UIKit is actually transitioning.
  @MainActor
  enum UIActivity {
    private static let log = Logger(subsystem: "agentctl", category: "settle")
    private static var lastReason: String?

    static func isIdle() -> Bool {
      let reason = busyReason()
      if reason != lastReason {
        // `log stream --predicate 'subsystem == "agentctl"' --level debug` shows what holds a step's settling.
        log.debug("UI \(reason.map { "busy: \($0)" } ?? "idle", privacy: .public)")
        lastReason = reason
      }
      return reason == nil
    }

    /// The first controller on screen with an animated transition in flight, and what it is doing; `nil` when idle.
    static func busyReason() -> String? {
      for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
      where scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
        for window in scene.windows where !window.isHidden {
          if let root = window.rootViewController, let reason = transition(in: root) { return reason }
        }
      }
      return nil
    }

    static func transition(in controller: UIViewController) -> String? {
      if controller.viewIfLoaded?.window != nil, let coordinator = controller.transitionCoordinator,
        coordinator.isAnimated
      {
        let kind = [
          controller.isBeingPresented ? "presenting" : nil, controller.isBeingDismissed ? "dismissing" : nil,
          controller.isMovingToParent ? "moving in" : nil, controller.isMovingFromParent ? "moving out" : nil,
        ].compactMap { $0 }
        return "\(type(of: controller)) \(kind.isEmpty ? "transitioning" : kind.joined(separator: ", "))"
      }
      let next = controller.children + (controller.presentedViewController.map { [$0] } ?? [])
      for child in next {
        if let reason = transition(in: child) { return reason }
      }
      return nil
    }
  }
#endif
