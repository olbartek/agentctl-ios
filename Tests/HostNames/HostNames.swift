// A host module that uses the common words a real app may already have declared publicly. nzozopole-ios has its own
// `PermissionStatus`, and 0.6.0's first candidate, which declared one at the top level of AgentCtlCore, broke every
// module of it that imported both ("'PermissionStatus' is ambiguous for type lookup").
//
// Every new public top-level name AgentCtl adds starts with `Agent`; HostNamesTests imports this module beside every
// AgentCtl module and names each of these types unqualified, so a clash fails the build. Add a word here whenever a
// library type is named after one.

public enum PermissionStatus { case granted }
public enum BiometryResult { case success }
public enum DevicePhase { case foreground }
public struct DeviceLocation {}
public struct DeviceSurface {}
public struct DeviceConfig {}
public struct Device {}
public struct Permission {}
public struct Biometry {}
public struct Push {}
public struct PushNotification {}
public struct Location {}
public enum Phase { case active }
public struct Surface {}
public enum Subcommand { case none }
// 0.7: the driver seam and MVVM-C. `AppIntent` is also the AppIntents framework's protocol.
public struct AppIntent {}
public struct ScreenIntent {}
public struct Intent {}
public struct StoreDriver {}
public struct StoreDriving {}
public struct ObservationDriver {}
public struct ViewModelDriver {}
public struct AppFactory {}
public struct Driver {}
public struct Coordinator {}
public struct ViewModel {}
