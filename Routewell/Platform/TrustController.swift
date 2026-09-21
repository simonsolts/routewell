import Foundation
import Observation
import RoutewellKit

/// Owns the trusted-certificate list shown in Settings > Advanced. Starts
/// in-memory and, when a persisted store is available, switches to it during
/// `load()` — mirroring how `PersistenceController` loads its files.
@MainActor @Observable
final class TrustController {
    private(set) var trusted: [TrustedEndpoint] = []
    private var backing: any EndpointTrustStore
    private let atomicStore: AtomicJSONStore?

    init(atomicStore: AtomicJSONStore?) {
        self.atomicStore = atomicStore
        backing = InMemoryEndpointTrustStore()
    }

    func load() async {
        if let atomicStore, let persistent = try? await PersistentEndpointTrustStore(store: atomicStore) {
            backing = persistent
        }
        trusted = await backing.all()
    }

    func revoke(host: String, port: Int) async {
        try? await backing.revoke(host: host, port: port)
        trusted = await backing.all()
    }

    func approve(_ endpoint: TrustedEndpoint) async {
        try? await backing.approve(endpoint)
        trusted = await backing.all()
    }
}
