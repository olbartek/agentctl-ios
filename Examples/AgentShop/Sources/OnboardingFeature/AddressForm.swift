import AgentCtlCore
import ComposableArchitecture
import DeviceClients
import Models

/// A shipping address, saved for checkout. Optional: "Skip" moves on without one. "Continue" needs every field,
/// and a zip that is not five digits is refused with `invalidZip`.
///
/// "Use my location" asks for the location permission, then fills the street, city and zip from where the device
/// is: `locationDenied` when refused, `locationUnavailable` when the device has no location, `addressNotFound` for
/// a place the (mock) geocoder does not know.
@Reducer
public struct AddressForm {
  public enum Error: String, Swift.Error, Equatable, Sendable {
    case invalidZip
    case locationDenied
    case locationUnavailable
    case addressNotFound
  }

  /// The mock geocoder: the one place it knows.
  public static let knownPlaces: [AgentDevice.Location: Address] = [
    AgentDevice.Location(latitude: 37.3349, longitude: -122.009): Address(
      street: "1 Apple Park Way", city: "Cupertino", zip: "95014"
    )
  ]

  @ObservableState
  public struct State: Equatable, Sendable {
    public var address: Address
    public var error: Error?

    public init(address: Address = Address(), error: Error? = nil) {
      self.address = address
      self.error = error
    }

    public var canContinue: Bool { address.isComplete }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case continueTapped
    case skipTapped
    case useLocationTapped
    case located(Result<AgentDevice.Location, Error>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// `nil` when skipped.
      case finished(Address?)
    }
  }

  @Dependency(\.locationClient) var locationClient

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .useLocationTapped:
        state.error = nil
        return .run { [locationClient] send in
          let status = await locationClient.requestAuthorization()
          guard status == .granted || status == .limited else {
            await send(.located(.failure(.locationDenied)))
            return
          }
          guard let location = await locationClient.current() else {
            await send(.located(.failure(.locationUnavailable)))
            return
          }
          await send(.located(.success(location)))
        }

      case let .located(.success(location)):
        guard let place = Self.knownPlaces[location] else {
          state.error = .addressNotFound
          return .none
        }
        state.address.street = place.street
        state.address.city = place.city
        state.address.zip = place.zip
        return .none

      case let .located(.failure(error)):
        state.error = error
        return .none

      case .binding:
        state.error = nil
        return .none

      case .continueTapped:
        guard state.canContinue else { return .none }
        guard isValidZip(state.address.zip) else {
          state.error = .invalidZip
          return .none
        }
        return .send(.delegate(.finished(state.address)))

      case .skipTapped:
        return .send(.delegate(.finished(nil)))

      case .delegate:
        return .none
      }
    }
  }
}
