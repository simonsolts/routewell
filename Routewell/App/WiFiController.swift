import Foundation
import Observation
import RoutewellKit

/// The Wi-Fi screen's own state: the derived Overview, the dismissed
/// suggestions (this session only), the devices a suggestion highlights,
/// and the selected Radios lane. The reads live on `AppModel`.
@MainActor @Observable
final class WiFiController {
    private let model: AppModel
    private var dismissed: (token: SessionToken?, kinds: Set<WiFiSuggestion.Kind>) = (nil, [])
    var highlighted: Set<MACAddress> = []
    var selectedBand: WirelessBand = .ghz5

    init(model: AppModel) {
        self.model = model
    }

    /// Why parts that need SSH show "—", or `nil` when SSH data can come.
    var airState: WiFiAirState {
        guard model.sshConfigured else { return .notSetUp }
        guard let probe = model.sshProbe else { return .checking }
        return probe.capability.state == .supported ? .available : .notWorking
    }

    /// `nil` before the first successful `get_config` in this session.
    var overview: WiFiOverview? {
        guard let wireless = model.wireless else { return nil }
        let clients = model.clientInventory?.clients.map { client in
            WiFiClientInfo(client: client, name: ClientNaming.automatic(client: client, record: model.deviceRegistry.records[client.mac]).text)
        }
        let air = airState == .available ? model.wifiAir : nil
        return WiFiOverview(wireless: wireless, mlo: try? model.wifi?.mlo.get(), air: air, clients: clients)
    }

    var suggestions: [WiFiSuggestion] {
        let kinds = dismissed.token == model.session.expectedToken ? dismissed.kinds : []
        return (overview?.suggestions ?? []).filter { !kinds.contains($0.kind) }
    }

    func dismiss(_ suggestion: WiFiSuggestion) {
        let token = model.session.expectedToken
        if dismissed.token != token { dismissed = (token, []) }
        dismissed.kinds.insert(suggestion.kind)
        highlighted = []
    }

    func openRadios(_ band: WirelessBand) {
        selectedBand = band
        model.subpages[.wifi] = WiFiTab.radios.rawValue
    }

    func openMultiLink() {
        model.subpages[.wifi] = WiFiTab.multiLink.rawValue
    }
}

enum WiFiAirState: Equatable {
    case notSetUp, checking, notWorking, available
}
