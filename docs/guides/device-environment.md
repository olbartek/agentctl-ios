# The device environment

Mobile apps react to the device as much as to taps: a permission the user denied, a system prompt waiting for an
answer, a deep link, a push, the app going to the background, the network dropping, a location fix, Face ID. A
script drives all of these with one runtime command, `device`, the same headlessly and in the running app. The
device is **simulated in the app's process**: your permission, connectivity, location and biometry clients read
AgentCtl's `AgentDevice` (`\.agentDevice`) in their mock implementations, as your backends route through
`mockCall`. So no line touches the real OS: no real dialog, and nothing that kills the app or its bridge. (Driving
the real OS cannot do this: `simctl privacy` has no notifications, camera or Face ID, revoking a permission kills
the app, and the bridge cannot answer a system alert. The `app` wrappers in the last column do drive the real
simulator, for demos and real-OS checks.)

| Capability | Script command | What your app wires | What a step shows | Real OS (live only) |
|---|---|---|---|---|
| Permissions | `device permission <service> <not-determined\|granted\|denied\|limited>` | `permissions: ["notifications", …]`; fakes call `device.permission(_:)` / `await device.requestPermission(_:)` | what your screen's summary shows | `app permission grant\|revoke\|reset <service>` |
| System prompts | `device prompt <allow\|deny\|limited>` | nothing more: a request while `not-determined` shows the prompt | `prompt=<service>` until answered; `expect prompt=…` | — |
| Deep and universal links | `device open-url <url>` | `openURL: { url in … }` returns the root action, or `nil` for a link you don't handle | the screen the link opens | `app openurl <url>` (the app registers the scheme; iOS asks "Open in …?" first) |
| Push notifications | `device push <name> [tap]` | `pushes: [AgentPush(name, help:, received:, opened:)]` | what receiving or tapping it does | `app push <payload.json>` |
| Background / foreground | `device background`, `device foreground` | `scenePhase: { phase in … }` returns the root action | screen commands fail while in the background | — |
| Relaunch | `device relaunch` | `relaunch: true` | the fresh launch; what your clients stored, the device and the clock survive | `app launch --no-build` (the real process) |
| Network | `device network <online\|offline>` | `offlineErrorCode: "network"`; observers use `device.onlineUpdates()` | offline, every `mockCall` fails with that code | — |
| Location | `device location <lat>,<lon>\|none` | `location: true`; fakes read `device.location` / `device.locationUpdates()` | what your screen does with it | `app location <lat>,<lon>\|clear` |
| Biometry | `device biometry <enrolled\|unenrolled\|match\|fail>` | `biometry: true`; fakes call `await device.authenticateBiometry()` | `prompt=biometry` until `match` or `fail` | — |
| Appearance | — | — | — | `app appearance light\|dark` |

Every capability is opt-in: an app's `AgentDeviceConfig` (in `AppCtlConfig(device:)` and both hosts) enables the
subcommands it lists, and an app that enables none has no `device` command and prints exactly what it did before.
From AgentShop's [`Config.swift`](../../Examples/AgentShop/Sources/AgentShopCtl/Config.swift) and
[`DeviceClients.swift`](../../Examples/AgentShop/Sources/DeviceClients/DeviceClients.swift):

```swift
AgentDeviceConfig(
  permissions: ["notifications", "location"],
  openURL: { AppFeature.action(opening: $0) },
  pushes: [
    AgentPush("order-shipped", help: "Order #1002 has shipped.", received: .orderPushReceived, opened: .deepLinkOpened(.order(1002))),
    AgentPush("promo", help: "A new promo code: SAVE10.", opened: .deepLinkOpened(.shop)),
  ],
  scenePhase: { .scenePhaseChanged($0) },
  relaunch: true,
  offlineErrorCode: "network",
  location: true,
  biometry: true
)

// The notifications client's mock: the request waits for `device prompt allow|deny` while not-determined.
extension NotificationsClient: DependencyKey {
  public static let liveValue = NotificationsClient(
    requestAuthorization: {
      @Dependency(\.agentDevice) var device
      return await device.requestPermission("notifications")
    }
  )
}
```

A refused permission, from AgentShop:

```
$ ./appctl run "login-as alice; tab profile; order-updates on; device prompt deny"
…
> order-updates on
  screen=home/profile name=Alice email=alice@example.com orderUpdates=off faceID=off alert=none prompt=notifications
> device prompt deny
  screen=home/profile name=Alice email=alice@example.com orderUpdates=off faceID=off alert=none error=notificationsDenied
```

Outside a host (a preview, a Release build) the device is *undriven*: online, every request granted at once, so
nothing waits for a prompt no one can answer. The exact grammar, messages and exit codes are
[CONTRACT.md §2.4](../../CONTRACT.md#24-device-subcommand-arguments).
