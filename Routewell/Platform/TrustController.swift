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
    private let mode: BackendMode

    /// True once `load()` has switched to the persistent store. Mock mode
    /// never does this, even when an `atomicStore` was supplied, so trust
    /// decisions made against mock scenarios never leak onto disk.
    private(set) var isPersistent = false

    /// The live `EndpointTrustStore` backing this controller, for
    /// `LiveRouterBackend` and `URLSessionTransport` to read and write
    /// through directly. Always the same instance `approve`/`revoke` use.
    var store: any EndpointTrustStore { backing }

    init(atomicStore: AtomicJSONStore?, mode: BackendMode) {
        self.atomicStore = atomicStore
        self.mode = mode
        backing = InMemoryEndpointTrustStore()
    }

    func load() async {
        if mode == .live, let atomicStore, let persistent = try? await PersistentEndpointTrustStore(store: atomicStore) {
            backing = persistent
            isPersistent = true
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
