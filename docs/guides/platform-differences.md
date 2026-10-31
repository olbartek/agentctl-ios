# Differences from agentctl-android

[agentctl-android](https://github.com/olbartek/agentctl-android) is the Kotlin port of this package. The two implement
the same [`CONTRACT.md`](../../CONTRACT.md), run the same scenario files and print the same bytes; where Kotlin or
Android forces a difference, the port records it in
[its own platform-differences guide](https://github.com/olbartek/agentctl-android/blob/main/docs/guides/platform-differences.md),
the full list. This page maps the types whose names do not line up, from this side.

## Starting the bridge in the app

| Role | iOS (this package) | Android |
|---|---|---|
| The launch arguments (CONTRACT.md §8.2) | `AgentLaunchOptions` (`AgentLaunch.Options` is an alias) | `AgentLaunchOptions` |
| Whether an agent launched the app; a token for a UI test | `AgentLaunchArguments.isRequested()`, `makeToken()` | `AgentLaunchArguments.isRequested(intent)`, `makeToken()` |
| The launch, for any UI: the token gate, `-clear-session`, the live host, the seed and the bridge, reporting a new app and the end of the seed | `AgentLaunchSession` (iOS 16+; `onAppChange`, `onReady` closures) | `AgentLaunch` (`apps` and `isReady` as `StateFlow`s, for Views or Compose) |
| The same, observed by SwiftUI | `AgentLaunch` (`@Observable`, iOS 17+), a wrapper over a session | — (Compose collects `AgentLaunch`'s flows) |
| The lower-level launch, with no app framework | — (`AgentLaunchSession` needs none) | `AgentLaunchSession` in agentctl-runtime, on the JVM |

So the name `AgentLaunchSession` means different things on the two sides: here it is the launch an app keeps (the role
Android's `AgentLaunch` plays), there it is the JVM piece under Android's `AgentLaunch`. Code that names the role is
the same on both; code that names the type is not.

## Before 1.0

The differences above are to be settled by 1.0; [Before 1.0](before-1.0.md) lists them.
