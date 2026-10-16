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
    /// DEBUG builds run the store through AgentCtlBridge when an agent launched the app — the CLI's `app` commands
    /// and the UI tests pass a well-formed `-agent-token` — with the localhost command server, launch seeding and the
    /// `-mock-latency` / `-clear-session` launch arguments. Any other launch (⌘R from Xcode) is the plain app.
    @State private var launch = AgentLaunchArguments.isRequested() ? AgentLaunch(config: AgentShopConfig.appCtl) : nil
  #endif
  /// The plain app's store: a Release build's, and a DEBUG build's that no agent launched.
  @State private var store = Store(initialState: AppFeature.State()) { AppFeature() }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if let launch {
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
        } else {
          plainRoot
        }
      #else
        plainRoot
      #endif
    }
  }

  private var plainRoot: some View {
    RootView(store: store)
      .onOpenURL { url in
        if let action = AppFeature.action(opening: url) { store.send(action) }
      }
  }
}
