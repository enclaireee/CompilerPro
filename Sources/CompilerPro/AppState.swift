import AppKit
import Combine
import CompilerProCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct AppAlert: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
}

@MainActor
public final class AppState: ObservableObject {
    public enum Screen {
        case welcome
        case workspace(WorkspaceViewModel)
    }

    @Published public var screen: Screen = .welcome
    @Published public var recents: [RecentProject] = []
    @Published public var texFound: Bool = false
    @Published public var texPath: String?
    @Published public var alert: AppAlert?
    @Published public var statusMessage: String?
    @Published public var showNewProjectSheet = false

    private let recentsKey = "cp.swift.recents"
    private let sessionKey = "cp.swift.session"
    private let themeKey = "cp.swift.theme"
    private var statusTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

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

    public var activeWorkspace: WorkspaceViewModel? {
        if case .workspace(let vm) = screen {
            return vm
        }
        return nil
    }

    /// Errors raise an alert; everything else goes to the status bar and VoiceOver.
    public func showToast(_ text: String, isError: Bool = false) {
        if isError {
            alert = AppAlert(title: "Something went wrong", message: text)
            return
        }
        statusTask?.cancel()
        statusMessage = text
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        statusTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
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

    public func restoreLastSessionIfAvailable() {
        guard UserDefaults.standard.bool(forKey: AppSettings.restoreSession),
              let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(WorkspaceSession.self, from: data),
              FileManager.default.fileExists(atPath: session.folder) else {
            return
        }
        enterWorkspace(mode: session.mode, folder: session.folder, file: session.file)
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

    private func saveSession(_ session: WorkspaceSession?) {
        if let session, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
    }

    // MARK: - Navigation & File Pickers

    public func enterWorkspace(mode: WorkspaceMode, folder: String, file: String?) {
        if let current = activeWorkspace {
            guard current.confirmCloseIfNeeded() else { return }
            current.teardown()
        }
        let vm = WorkspaceViewModel(
            mode: mode,
            folder: folder,
            initialFile: file,
            appState: self
        )
        screen = .workspace(vm)
        saveSession(WorkspaceSession(mode: mode, folder: folder, file: vm.currentFile))
        rememberRecent(mode: mode, folder: folder, file: vm.currentFile)
    }

    public func notifyFileChanged(mode: WorkspaceMode, folder: String, file: String?) {
        saveSession(WorkspaceSession(mode: mode, folder: folder, file: file))
        rememberRecent(mode: mode, folder: folder, file: file)
    }

    public func goHome() {
        if let current = activeWorkspace {
            guard current.confirmCloseIfNeeded() else { return }
            current.teardown()
        }
        saveSession(nil)
        screen = .welcome
        NSApp.mainWindow?.title = "CompilerPro"
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
        alert.informativeText = "CompilerPro couldn't tell from the files inside. Pick how to open it."
        for m in WorkspaceMode.allCases { alert.addButton(withTitle: m.displayName) }
        alert.addButton(withTitle: "Cancel")
        let r = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return WorkspaceMode.allCases.indices.contains(r) ? WorkspaceMode.allCases[r] : nil
    }

    public func createProject(mode: WorkspaceMode, name: String, in directory: URL) {
        let dirURL = directory.appendingPathComponent(name, isDirectory: true)
        let starter = mode.starterFile
        let fileURL = dirURL.appendingPathComponent(starter.name)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false)
            try FileService.atomicWriteText(path: fileURL.path, contents: starter.contents)
            enterWorkspace(mode: mode, folder: dirURL.path, file: fileURL.path)
        } catch {
            alert = AppAlert(title: "Couldn't create “\(name)”", message: error.localizedDescription)
        }
    }

    public func openGettingStarted() {
        showNewProjectSheet = true
    }

    public func openExternalPath(_ path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            showToast("File no longer exists: \(path)", isError: true)
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
            showToast("CompilerPro opens .tex, .mmd, and .md files (got \(name))", isError: true)
            return
        }
        if let ws = activeWorkspace, ws.mode == mode, path.hasPrefix(ws.folder + "/") {
            ws.openFile(path)
            return
        }
        let folder = (path as NSString).deletingLastPathComponent
        enterWorkspace(mode: mode, folder: folder, file: path)
    }

    public func openRecent(_ recent: RecentProject) {
        guard FileManager.default.fileExists(atPath: recent.folder) else {
            removeRecent(recent)
            showToast("\(recent.abbreviatedFolder) no longer exists", isError: true)
            return
        }
        enterWorkspace(mode: recent.mode, folder: recent.folder, file: recent.file)
    }
}
