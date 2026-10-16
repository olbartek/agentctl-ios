import AgentCtlBridge
import AgentCtlCLI
import AgentCtlCore
import AgentCtlObservation
import AgentCtlRuntime
import AgentCtlTCA
import AgentCtlTestSupport
import HostNames
import Testing

/// Each of the host's names in a type position, unqualified: what fails with "is ambiguous for type lookup" when an
/// AgentCtl module declares the same name at its top level.
private struct UsesHostNames {
  var permissionStatus: PermissionStatus?
  var biometryResult: BiometryResult?
  var devicePhase: DevicePhase?
  var deviceLocation: DeviceLocation?
  var deviceSurface: DeviceSurface?
  var deviceConfig: DeviceConfig?
  var device: Device?
  var permission: Permission?
  var biometry: Biometry?
  var push: Push?
  var pushNotification: PushNotification?
  var location: Location?
  var phase: Phase?
  var surface: Surface?
  var subcommand: Subcommand?
  var appIntent: AppIntent?
  var screenIntent: ScreenIntent?
  var intent: Intent?
  var storeDriver: StoreDriver?
  var storeDriving: StoreDriving?
  var observationDriver: ObservationDriver?
  var viewModelDriver: ViewModelDriver?
  var appFactory: AppFactory?
  var driver: Driver?
  var coordinator: Coordinator?
  var viewModel: ViewModel?
}

/// What this guards: a host that declares common words of its own still compiles beside every AgentCtl module (see
/// `Tests/HostNames`). The real assertion is that this file compiles.
struct HostNamesTests {
  @Test func aHostsOwnNamesStayUnambiguous() {
    let types = Mirror(reflecting: UsesHostNames()).children.map { String(reflecting: type(of: $0.value)) }
    #expect(types.count == 26)
    #expect(types.allSatisfy { $0.contains("HostNames.") })
  }
}
