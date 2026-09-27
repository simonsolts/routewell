import Foundation
import RoutewellKit

/// Keeps the chosen SSH key file readable in the App Sandbox. The open panel
/// grants access only until the app quits, so Routewell stores a
/// security-scoped bookmark and opens it again on each launch. `ssh` runs as
/// a child process and shares this access. Without the sandbox, the bookmark
/// is not needed and the plain path still works.
@MainActor
final class SSHKeyFileAccess {
    private var accessed: URL?

    /// Makes a bookmark for a key file the person just chose, while the open
    /// panel's access is still active.
    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Starts access to the key file that `settings` names and stops access
    /// to the one before. Returns new settings to save when the bookmark was
    /// stale or the file moved, or `nil` when nothing changed.
    func activate(_ settings: SSHSettings?) -> SSHSettings? {
        guard let settings, !settings.useAgent, let bookmark = settings.keyFileBookmark else {
            stop()
            return nil
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) else {
            stop()
            return nil
        }
        if url != accessed {
            stop()
            if url.startAccessingSecurityScopedResource() { accessed = url }
        }
        guard stale || url.path != settings.keyFilePath else { return nil }
        var refreshed = settings
        refreshed.keyFilePath = url.path
        refreshed.keyFileBookmark = Self.bookmark(for: url) ?? bookmark
        return refreshed
    }

    private func stop() {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
    }
}

enum AppSandbox {
    /// True when the App Sandbox runs this process. The sandbox blocks the
    /// SSH agent's socket, so agent sign-in is not offered.
    static let isActive = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
}
