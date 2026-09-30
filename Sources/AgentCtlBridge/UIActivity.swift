#if DEBUG && canImport(UIKit)
  import UIKit

  /// Whether UIKit is between screens: a navigation push or pop, or a presentation or dismissal, still animating.
  ///
  /// SwiftUI's `NavigationStack` and sheets run on view controllers, so their transitions show up here. A command sent
  /// mid-transition can be lost (a push that lands during a pop's animation may never be shown), so a live step settles
  /// only once no transition is in flight.
  @MainActor
  enum UIActivity {
    static func isIdle() -> Bool {
      for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
      where scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
        for window in scene.windows {
          if let root = window.rootViewController, isTransitioning(root) { return false }
        }
      }
      return true
    }

    static func isTransitioning(_ controller: UIViewController) -> Bool {
      if controller.transitionCoordinator != nil || controller.isBeingPresented || controller.isBeingDismissed
        || controller.isMovingToParent || controller.isMovingFromParent
      {
        return true
      }
      let next = controller.children + (controller.presentedViewController.map { [$0] } ?? [])
      return next.contains(where: isTransitioning)
    }
  }
#endif
