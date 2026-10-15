import AppFeature
import ComposableArchitecture
import SwiftUI

#if DEBUG
  import AgentCtlBridge
  import AgentShopCtl
#endif

@main
struct AgentShopApp: App {
  #if DEBUG
    /// DEBUG builds run the store through AgentCtlBridge: the localhost command server, launch seeding and
    /// the `-mock-latency` / `-clear-session` launch arguments.
    @State private var launch = AgentLaunch(config: AgentShopConfig.appCtl)
  #else
    let store = Store(initialState: AppFeature.State()) { AppFeature() }
  #endif

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        Group {
          if launch.isReady {
            // Keyed by the store, so `device relaunch` (a new store) shows a fresh view tree, as a relaunch would.
            RootView(store: launch.app)
              .id(ObjectIdentifier(launch.app))
          } else {
            ProgressView()
          }
        }
        .task { await launch.start() }
        // A link the system opens (`app openurl agentshop://order/1003`): the same action `device open-url` sends.
        .onOpenURL { url in
          if let action = AppFeature.action(opening: url) { launch.app.send(action) }
        }
      #else
        RootView(store: store)
          .onOpenURL { url in
            if let action = AppFeature.action(opening: url) { store.send(action) }
          }
      #endif
    }
  }
}
