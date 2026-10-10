import Foundation
import RoutewellKit

/// Text for AdGuard Home › Instance's update, backups, and data sections.
enum AdGuardInstancePresentation {
    static let updaterGuide = URL(string: "https://github.com/Admonstrator/glinet-adguard-updater")!
    static let updaterCredit = "glinet-adguard-updater is a community tool by Admonstrator and contributors."
    static let backupsFootnote = "Includes filters, rules, DNS settings and clients — not the log or stats."

    // MARK: Software update

    struct Update: Equatable {
        let title: String
        let subtitle: String
    }

    static func update(_ check: AdGuardVersionCheck?, current: String?) -> Update {
        let have = current.map { "You have \($0)." } ?? "Version unknown."
        switch check?.update(current: current) ?? .unknown {
        case .available(let version): return Update(title: "Version \(version) is available", subtitle: have)
        case .upToDate: return Update(title: "AdGuard Home is up to date", subtitle: have)
        case .unknown: return Update(title: "Update check not available", subtitle: have)
        }
    }

    // MARK: Backups

    static func note(_ kind: AdGuardBackup.Kind) -> String {
        switch kind {
        case .manual: "Manual backup"
        case .beforeRestore: "Before restore"
        }
    }

    /// "Today at 15:02" or "Oct 7 at 15:02".
    static func date(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }

    /// "Manual backup · 14 KB".
    static func detail(_ backup: AdGuardBackup) -> String {
        "\(note(backup.kind)) · \(size(backup.size))"
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func lastBackup(_ backups: [AdGuardBackup], now: Date) -> String {
        guard let newest = backups.first else { return "No backups yet" }
        let text = date(newest.createdAt, now: now)
        return "Last backup: " + text.prefix(1).lowercased() + text.dropFirst()
    }

    static let notSaved = "Routewell could not save the backup on this Mac."
    static let exportFailed = "Routewell could not write the exported file."
    static let backupMissing = "This backup's file is missing or damaged on this Mac. Nothing was restored."

    static func backupFailureText(_ failure: AdGuardBackupFailure) -> String {
        switch failure {
        case .notRunning: "AdGuard Home is not running."
        case .unreadable: "Routewell could not read AdGuard Home's settings over SSH. Nothing was saved."
        case .notConfigFile: "The router did not send an AdGuard Home settings file. Nothing was saved."
        }
    }

    /// `nil` when the restore did what was asked.
    static func restoreText(_ outcome: MutationOutcome<AdGuardRestoreState>) -> String? {
        switch outcome {
        case .verifiedSuccess: nil
        case .verifiedRecovery:
            "AdGuard Home did not start correctly with that backup, so Routewell put the earlier settings back."
        case .recoveryFailed:
            "AdGuard Home did not start correctly with that backup, and putting the earlier settings back did not work. Restore the “Before restore” backup, or check AdGuard Home on the router."
        case .verifiedMismatch:
            "The router did not stop AdGuard Home, so nothing was restored."
        case .conflictingExternalEdit, .unknownAfterDispatch:
            "AdGuard Home did not answer in time. Refresh to check."
        case .rejected(.capabilityUnavailable):
            "Restore needs SSH and an AdGuard Home connection."
        case .rejected(.preconditionFailed(let reason)), .rejected(.invalidIntent(let reason)):
            reason
        case .rejected:
            "Another change is still running."
        }
    }

    static let restoreTitle = "Restore this backup?"
    static func restoreMessage(_ backup: AdGuardBackup, now: Date) -> String {
        let when = date(backup.createdAt, now: now)
        return "AdGuard Home restarts with the settings from \(when.prefix(1).lowercased() + when.dropFirst()). Routewell backs up the current settings first."
    }

    // MARK: Data

    static func retention(_ milliseconds: Int) -> String {
        let hours = milliseconds / AdGuardRetention.hour
        if hours % 24 == 0 { return hours == 24 ? "24 hours" : "\(hours / 24) days" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// The four options, plus the router's own value when it is another one.
    static func retentionOptions(current: Int?) -> [Int] {
        guard let current, AdGuardRetention.isValid(current), !AdGuardRetention.options.contains(current) else { return AdGuardRetention.options }
        return (AdGuardRetention.options + [current]).sorted()
    }

    /// The query log row's subtitle.
    static func queryLogSize(_ resources: AdGuardResources?, sshConfigured: Bool) -> String? {
        guard sshConfigured else { return "Size on the router needs SSH" }
        guard case .value(let bytes)? = resources?.queryLogBytes else { return nil }
        return "Currently \(size(bytes)) on the router"
    }

    static func clearTitle(_ kind: AdGuardDataKind) -> String {
        kind == .queryLog ? "Clear the query log?" : "Clear statistics?"
    }

    static func clearMessage(_ kind: AdGuardDataKind) -> String {
        kind == .queryLog ? "This deletes the query log on the router. You can't undo this."
            : "This resets all statistics on the router. You can't undo this."
    }

    static func clearAction(_ kind: AdGuardDataKind) -> String {
        kind == .queryLog ? "Clear Query Log" : "Clear Statistics"
    }
}
