import AppKit
import Combine
import ProofCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct AppAlert: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
}

/// Identity of a project window. Opening a ref that already has a window brings that window forward.
public struct ProjectRef: Codable, Hashable {
    public let mode: WorkspaceMode
    public let folder: String
}

/// App-wide state: recents, TeX status, and the registry of open project windows.
/// Per-project state lives in each window's `WorkspaceViewModel`.
@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()
    public static let welcomeWindowID = "welcome"

    @Published public var recents: [RecentProject] = []
    @Published public var texFound: Bool = false
    @Published public var texPath: String?
    @Published public var showNewProjectSheet = false
    @Published public private(set) var openWorkspaces: [ProjectRef: WorkspaceViewModel] = [:]

    /// Set when quitting so windows closing on the way out don't wipe the saved session.
    public var isTerminating = false

    private let recentsKey = "cp.swift.recents"
    private let legacySessionKey = "cp.swift.session"
    private let sessionsKey = "cp.swift.sessions"
    private let themeKey = "cp.swift.theme"
    private var defaultsObserver: NSObjectProtocol?

    private var openWindow: OpenWindowAction?
    private var dismissWindow: DismissWindowAction?
    private var didLaunch = false
    /// Projects requested before any window could open them (Finder "Open With" at launch).
    private var queuedOpens: [(ProjectRef, String?)] = []
    /// File to show first in a project window that is about to be created.
    private var pendingFiles: [ProjectRef: String] = [:]

    public init() {
        loadPersistedState()
        applyTheme()
        checkTexEnvironment()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    /// App-level errors aren't tied to a window, so they use a modal alert.
    public func showError(_ text: String, title: String = "Something went wrong") {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: - Appearance

    public func applyTheme() {
        let raw = UserDefaults.standard.string(forKey: AppSettings.appearance) ?? ""
        let pref = AppThemePreference(rawValue: raw) ?? .auto
        let appearance: NSAppearance? = switch pref {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        if NSApp?.appearance != appearance { NSApp?.appearance = appearance }
    }

    // MARK: - TeX Live Status

    public func checkTexEnvironment() {
        let custom = UserDefaults.standard.string(forKey: AppSettings.texPath) ?? ""
        let override = custom.isEmpty ? nil : custom
        Task.detached(priority: .utility) {
            let path = TexService.texbin(override: override)
            await MainActor.run {
                self.texFound = (path != nil)
                self.texPath = path
            }
        }
    }

    /// Re-probe the filesystem (after installing MacTeX or changing the TeX folder).
    public func recheckTex() {
        Task.detached(priority: .utility) {
            _ = TexService.refreshTexbin()
            await self.checkTexEnvironment()
        }
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        // One-time migration of the old theme key.
        let defaults = UserDefaults.standard
        if let old = defaults.string(forKey: themeKey) {
            if defaults.object(forKey: AppSettings.appearance) == nil {
                defaults.set(old, forKey: AppSettings.appearance)
            }
            defaults.removeObject(forKey: themeKey)
        }
        if let data = UserDefaults.standard.data(forKey: recentsKey),
           let decoded = try? JSONDecoder().decode([RecentProject].self, from: data) {
            recents = decoded
        }
    }

    /// Reopens every project that was open at last quit.
    private func restoreLastSessionIfAvailable() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettings.restoreSession) else { return }
        var sessions: [WorkspaceSession] = []
        if let data = defaults.data(forKey: sessionsKey),
           let decoded = try? JSONDecoder().decode([WorkspaceSession].self, from: data) {
            sessions = decoded
        } else if let data = defaults.data(forKey: legacySessionKey),
                  let single = try? JSONDecoder().decode(WorkspaceSession.self, from: data) {
            sessions = [single]
        }
        defaults.removeObject(forKey: legacySessionKey)
        for session in sessions where FileManager.default.fileExists(atPath: session.folder) {
            enterWorkspace(mode: session.mode, folder: session.folder, file: session.file)
        }
    }

    private func saveSessions() {
        guard !isTerminating else { return }
        let sessions = openWorkspaces.values.map {
            WorkspaceSession(mode: $0.mode, folder: $0.folder, file: $0.currentFile)
        }
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: sessionsKey)
        }
    }

    public func rememberRecent(mode: WorkspaceMode, folder: String, file: String?) {
        var updated = recents.filter { !($0.folder == folder && $0.mode == mode) }
        updated.insert(RecentProject(mode: mode, folder: folder, file: file), at: 0)
        if updated.count > 12 {
            updated = Array(updated.prefix(12))
        }
        recents = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    public func removeRecent(_ recent: RecentProject) {
        recents.removeAll { $0.id == recent.id }
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    public func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
    }

    // MARK: - Windows

    /// Called by every window's root view; the first call also handles launch (Finder opens or session restore).
    public func attach(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        self.openWindow = openWindow
        self.dismissWindow = dismissWindow
        guard !didLaunch else { return }
        didLaunch = true
        let queued = queuedOpens
        queuedOpens = []
        if queued.isEmpty {
            restoreLastSessionIfAvailable()
        } else {
            for (ref, file) in queued { enterWorkspace(mode: ref.mode, folder: ref.folder, file: file) }
        }
    }

    public func showWelcome() {
        openWindow?(id: Self.welcomeWindowID)
    }

    public func newProject() {
        showNewProjectSheet = true
        showWelcome()
    }

    /// Opens (or focuses) the project's window, showing `file` in it.
    public func enterWorkspace(mode: WorkspaceMode, folder: String, file: String?) {
        let ref = ProjectRef(mode: mode, folder: folder)
        guard let openWindow else {
            queuedOpens.append((ref, file))
            return
        }
        if let vm = openWorkspaces[ref] {
            if let file { vm.openFile(file) }
        } else if let file {
            pendingFiles[ref] = file
        }
        openWindow(value: ref)
        dismissWindow?(id: Self.welcomeWindowID)
    }

    /// Hands a new project window the file it was opened for (once).
    public func takePendingFile(for ref: ProjectRef) -> String? {
        pendingFiles.removeValue(forKey: ref)
    }

    public func register(_ vm: WorkspaceViewModel) {
        let ref = ProjectRef(mode: vm.mode, folder: vm.folder)
        openWorkspaces[ref] = vm
        pendingFiles[ref] = nil
        saveSessions()
        rememberRecent(mode: vm.mode, folder: vm.folder, file: vm.currentFile)
    }

    public func unregister(_ vm: WorkspaceViewModel) {
        let ref = ProjectRef(mode: vm.mode, folder: vm.folder)
        // A replaced window for the same ref may already have registered.
        guard openWorkspaces[ref] === vm else { return }
        openWorkspaces[ref] = nil
        saveSessions()
        // Next runloop turn, so a project window that is still opening can register first.
        DispatchQueue.main.async { [self] in
            if openWorkspaces.isEmpty && !isTerminating { showWelcome() }
        }
    }

    public func notifyFileChanged(mode: WorkspaceMode, folder: String, file: String?) {
        saveSessions()
        rememberRecent(mode: mode, folder: folder, file: file)
    }

    /// One panel for files and folders; mode comes from the file extension or folder contents.
    public func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.message = "Choose a project folder or a .tex, .mmd or .md file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = WorkspaceMode.allCases
            .flatMap(\.extensions).compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openExternalPath(url.path)
    }

    /// Modes whose files appear in `folder` (shallow plus one level, skipping hidden and .build).
    private func detectModes(in folder: String) -> [WorkspaceMode] {
        let fm = FileManager.default
        var found = Set<WorkspaceMode>()
        func scan(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names where !name.hasPrefix(".") && name != ".build" {
                let path = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if depth < 1 { scan(path, depth: depth + 1) }
                } else if let m = WorkspaceMode.mode(forPath: path) {
                    found.insert(m)
                }
            }
        }
        scan(folder, depth: 0)
        return WorkspaceMode.allCases.filter(found.contains)
    }

    private func askMode(for folder: String) -> WorkspaceMode? {
        let alert = NSAlert()
        alert.messageText = "What kind of project is “\((folder as NSString).lastPathComponent)”?"
        alert.informativeText = "Proof couldn't tell from the files inside. Pick how to open it."
        for m in WorkspaceMode.allCases { alert.addButton(withTitle: m.displayName) }
        alert.addButton(withTitle: "Cancel")
        let r = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return WorkspaceMode.allCases.indices.contains(r) ? WorkspaceMode.allCases[r] : nil
    }

    public func createProject(mode: WorkspaceMode, name: String, in directory: URL) {
        // The Welcome window may close before the sheet's own dismiss runs; don't let it reopen with the sheet up.
        showNewProjectSheet = false
        let dirURL = directory.appendingPathComponent(name, isDirectory: true)
        let starter = mode.starterFile
        let fileURL = dirURL.appendingPathComponent(starter.name)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false)
            try FileService.atomicWriteText(path: fileURL.path, contents: starter.contents)
            enterWorkspace(mode: mode, folder: dirURL.path, file: fileURL.path)
        } catch {
            showError(error.localizedDescription, title: "Couldn't create “\(name)”")
        }
    }

    public func openGettingStarted() {
        newProject()
    }

    public func openExternalPath(_ path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            showError("File no longer exists: \(path)")
            return
        }
        if isDir.boolValue {
            let modes = detectModes(in: path)
            if modes.count == 1 {
                enterWorkspace(mode: modes[0], folder: path, file: nil)
            } else if let mode = askMode(for: path) {
                enterWorkspace(mode: mode, folder: path, file: nil)
            }
            return
        }
        guard let mode = WorkspaceMode.mode(forPath: path) else {
            let name = (path as NSString).lastPathComponent
            showError("Proof opens .tex, .mmd, and .md files (got \(name))")
            return
        }
        if let ws = openWorkspaces.values.first(where: { $0.mode == mode && path.hasPrefix($0.folder + "/") }) {
            enterWorkspace(mode: mode, folder: ws.folder, file: path)
            return
        }
        let folder = (path as NSString).deletingLastPathComponent
        enterWorkspace(mode: mode, folder: folder, file: path)
    }

    public func openRecent(_ recent: RecentProject) {
        guard FileManager.default.fileExists(atPath: recent.folder) else {
            removeRecent(recent)
            showError("\(recent.abbreviatedFolder) no longer exists")
            return
        }
        enterWorkspace(mode: recent.mode, folder: recent.folder, file: recent.file)
    }
}
