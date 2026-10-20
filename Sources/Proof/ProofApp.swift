import AppKit
import ProofCore
import SwiftUI

@main
public struct ProofApp: App {
    @NSApplicationDelegateAdaptor(ProofAppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    public init() { AppSettings.registerDefaults() }

    public var body: some Scene {
        // Xcode-style: a compact Welcome window, and one window per open project.
        Window("Welcome to Proof", id: AppState.welcomeWindowID) {
            WelcomeView(appState: appState)
                .frame(width: 820, height: 500)
                .attachingWindowActions(appState)
                .openingDroppedFiles(appState)
                .sheet(isPresented: $appState.showNewProjectSheet) {
                    NewProjectSheet(appState: appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { AppCommands(appState: appState) }

        // Separate windows get native macOS tabs (Window ▸ Merge All Windows) and side-by-side tiling for free.
        WindowGroup(id: "project", for: ProjectRef.self) { $ref in
            if let ref {
                ProjectWindow(ref: ref, appState: appState)
            }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .defaultLaunchBehavior(.suppressed)
        // Our own session restore honours the "Reopen projects" setting.
        .restorationBehavior(.disabled)

        Settings { SettingsView(appState: appState) }
    }
}

private struct AppCommands: Commands {
    @ObservedObject var appState: AppState
    @FocusedObject private var workspace: WorkspaceViewModel?

    private var isLatex: Bool { workspace?.mode == .latex }
    private var canZoom: Bool { workspace?.mode == .latex || workspace?.mode == .mermaid }
    private func layoutButton(_ title: String, _ layout: EditorLayout, _ key: KeyEquivalent) -> some View {
        Button {
            workspace?.setLayout(layout)
        } label: {
            if workspace?.layout == layout { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .keyboardShortcut(key, modifiers: [.command, .option])
        .disabled(workspace == nil)
    }

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        TextEditingCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Project…") { appState.newProject() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New File") { workspace?.createNewFile() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("Open…") { appState.openPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                ForEach(appState.recents) { recent in
                    Button(recent.displayLabel) { appState.openRecent(recent) }
                }
                Divider()
                Button("Clear Menu") { appState.clearRecents() }
                    .disabled(appState.recents.isEmpty)
            }
            Button("Open Quickly…") { workspace?.toggleQuickOpen() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspace?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(workspace?.isDirty != true)
            Button("Export…") { workspace?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Divider()
            // Replacing .saveItem also removes the system Close item, so restore it.
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Close Project") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button(workspace?.isProblemsVisible == true ? "Hide Problems" : "Show Problems") {
                workspace?.toggleProblems()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!isLatex)
            Divider()
            layoutButton("Editor Only", .editor, "1")
            layoutButton("Editor and Preview", .split, "2")
            layoutButton("Preview Only", .preview, "3")
            Divider()
            Button("Zoom In") { workspace?.zoom(.zoomIn) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!canZoom)
            Button("Zoom Out") { workspace?.zoom(.zoomOut) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!canZoom)
            Button("Fit Width") { workspace?.zoom(.fitWidth) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!isLatex)
            Button("Fit Page") { workspace?.zoom(.fitPage) }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(!isLatex)
            Button("Actual Size") { workspace?.zoom(.actualSize) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!canZoom)
        }

        CommandMenu("Build") {
            Button(workspace?.isCompiling == true ? "Stop Compiling" : "Compile") {
                workspace?.compileOrStop()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!isLatex)
            Button("Stop") { workspace?.stopCompile() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!isLatex || workspace?.isCompiling != true)
            Divider()
            Button("Show in PDF") { workspace?.syncForward() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(!isLatex)
            Divider()
            Button("Next Problem") { workspace?.nextProblem() }
                .keyboardShortcut("'", modifiers: .command)
                .disabled(!isLatex || (workspace?.problemCount ?? 0) == 0)
            Button("Previous Problem") { workspace?.previousProblem() }
                .keyboardShortcut("'", modifiers: [.command, .shift])
                .disabled(!isLatex || (workspace?.problemCount ?? 0) == 0)
            Divider()
            Button("Clean Build Files…") { workspace?.cleanBuild() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!isLatex)
        }

        CommandGroup(replacing: .help) {
            Button("Getting Started") { appState.openGettingStarted() }
            if let url = URL(string: "https://www.tug.org/mactex/") {
                Link("Get MacTeX…", destination: url)
            }
        }
    }
}

/// One project window. Owns its view model for the window's lifetime.
private struct ProjectWindow: View {
    let appState: AppState
    @StateObject private var viewModel: WorkspaceViewModel

    init(ref: ProjectRef, appState: AppState) {
        self.appState = appState
        _viewModel = StateObject(wrappedValue: WorkspaceViewModel(
            mode: ref.mode,
            folder: ref.folder,
            initialFile: appState.takePendingFile(for: ref),
            appState: appState
        ))
    }

    var body: some View {
        WorkspaceView(viewModel: viewModel, appState: appState)
            .attachingWindowActions(appState)
            .openingDroppedFiles(appState)
            // Teardown happens on the window's real close (WorkspaceView's WindowStateBinder).
            .onAppear { appState.register(viewModel) }
    }
}

private extension View {
    /// Gives AppState the window actions so menus, Finder and the Dock can open windows.
    func attachingWindowActions(_ appState: AppState) -> some View {
        modifier(WindowActionsAttacher(appState: appState))
    }

    func openingDroppedFiles(_ appState: AppState) -> some View {
        modifier(FileDropTarget(appState: appState))
    }
}

private struct WindowActionsAttacher: ViewModifier {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear { appState.attach(openWindow: openWindow, dismissWindow: dismissWindow) }
    }
}

private struct FileDropTarget: ViewModifier {
    let appState: AppState
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let path = url?.path {
                            Task { @MainActor in appState.openExternalPath(path) }
                        }
                    }
                }
                return true
            }
    }
}

@MainActor
public final class ProofAppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState { .shared }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.module.resourceURL?.appendingPathComponent("Resources/AppIcon.icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        // Before the first window appears, AppState queues these and opens them instead of restoring.
        for url in urls where url.isFileURL {
            appState.openExternalPath(url.path)
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { appState.showWelcome() }
        return false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let workspaces = Array(appState.openWorkspaces.values)
        for ws in workspaces {
            guard ws.confirmCloseIfNeeded() else { return .terminateCancel }
        }
        appState.isTerminating = true
        workspaces.forEach { $0.teardown() }
        return .terminateNow
    }
}
