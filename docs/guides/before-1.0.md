# Before 1.0

Until 1.0, a minor version may change the API: a host that moves to it follows its "Moving a host to X.Y" notes in
[Releases](releases.md). The scripts, scenarios and step output change only with CONTRACT.md, in a minor release of
both libraries.

These are to be settled by 1.0:

- **`AgentLaunchSession` names two different things**: here it is the launch an app keeps, on Android the JVM piece under its `AgentLaunch` (see [Platform differences](platform-differences.md)). At 1.0 the two ports should agree on one name for the
  launch an app keeps, and one for the lower-level piece.
- **Android's tokenless `BridgeServer` constructors** from 0.8 stay, deprecated, until 1.0, so code built against them
  still links; this package's `BridgeServer` has always taken a token. They go at 1.0.
