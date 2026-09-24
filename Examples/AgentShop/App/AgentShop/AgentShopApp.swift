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
            RootView(store: launch.store)
          } else {
            ProgressView()
          }
        }
        .task { await launch.start() }
      #else
        RootView(store: store)
      #endif
    }
  }
}
