import AppKit
import ProofCore
import SwiftUI

/// Owns the update check: when it runs, what the user is told, and what the settings
/// screen shows. The download and install are deliberately out of scope for now — the
/// release page is opened instead.
@MainActor
public final class UpdateController: ObservableObject {
    public static let shared = UpdateController()

    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case noReleases
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastChecked: Date?

    public static let releasesURL = URL(string: "https://github.com/enclaireee/CompilerPro/releases")!

    private let checker: UpdateChecker
    private let defaults: UserDefaults
    private let checkInterval: TimeInterval = 24 * 60 * 60

    public init(checker: UpdateChecker = UpdateChecker(), defaults: UserDefaults = .standard) {
        self.checker = checker
        self.defaults = defaults
        self.lastChecked = defaults.object(forKey: AppSettings.lastUpdateCheck) as? Date
    }

    public var currentVersion: String { AppVersion.current }

    public var isChecking: Bool { state == .checking }

    /// Runs at launch. Says nothing unless there is an update the user hasn't been told about.
    public func checkIfDue() async {
        let automatic = defaults.object(forKey: AppSettings.autoCheckUpdates) as? Bool ?? true
        guard automatic else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < checkInterval { return }
        await run(silent: true)
    }

    /// From the menu or the settings button.
    public func checkForUpdates() {
        Task { await run(silent: false) }
    }

    private func run(silent: Bool) async {
        guard state != .checking else { return }
        state = .checking

        do {
            let release = try await checker.latestRelease()
            let now = Date()
            lastChecked = now
            defaults.set(now, forKey: AppSettings.lastUpdateCheck)

            guard let release else {
                state = .noReleases
                if !silent { alertNoReleases() }
                return
            }

            if AppVersion.isNewer(release.version, than: currentVersion) {
                state = .available(release)
                let alreadyOffered = defaults.string(forKey: AppSettings.offeredUpdateVersion) == release.version
                if !silent || !alreadyOffered {
                    defaults.set(release.version, forKey: AppSettings.offeredUpdateVersion)
                    offer(release)
                }
            } else {
                state = .upToDate
                if !silent { alertUpToDate() }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            if !silent { alertFailed(message) }
        }
    }

    // MARK: - Alerts

    private func offer(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Proof \(release.version) is available"
        alert.informativeText = noteText(for: release)
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.downloadURL)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    private func alertUpToDate() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Proof is up to date"
        alert.informativeText = "Version \(currentVersion) is the latest version."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func alertNoReleases() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No releases yet"
        alert.informativeText = "There is nothing published to download right now."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func alertFailed(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Keeps the sheet readable: a few lines of notes, not an entire changelog.
    private func noteText(for release: ReleaseInfo) -> String {
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            return "You're running \(currentVersion)."
        }
        let limit = 800
        let excerpt = notes.count > limit ? String(notes.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : notes
        return "You're running \(currentVersion).\n\n\(excerpt)"
    }
}
