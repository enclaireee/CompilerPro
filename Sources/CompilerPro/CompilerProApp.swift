import AppKit
import CompilerProCore
import SwiftUI

@main
public struct CompilerProApp: App {
    @NSApplicationDelegateAdaptor(CompilerAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    public init() { AppSettings.registerDefaults() }

    public var body: some Scene {
        Window("CompilerPro", id: "main") {
            RootContainerView(appState: appState)
                .onAppear {
                    appDelegate.appState = appState
                    if !appDelegate.pendingOpenPaths.isEmpty {
                        let paths = appDelegate.pendingOpenPaths
                        appDelegate.pendingOpenPaths.removeAll()
                        for path in paths {
                            appState.openExternalPath(path)
                        }
                    } else {
                        appState.restoreLastSessionIfAvailable()
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(appState: appState) }

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
            Button("New Project…") { appState.showNewProjectSheet = true }
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
            Button("Close Project") { appState.goHome() }
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

private struct RootContainerView: View {
    @ObservedObject var appState: AppState
    @State private var dropTargeted = false

    var body: some View {
        Group {
            switch appState.screen {
            case .welcome:
                WelcomeView(appState: appState)
            case .workspace(let vm):
                WorkspaceView(viewModel: vm, appState: appState)
            }
        }
        .sheet(isPresented: $appState.showNewProjectSheet) {
            NewProjectSheet(appState: appState)
        }
        .alert(item: $appState.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let path = url?.path {
                        Task { @MainActor in
                            appState.openExternalPath(path)
                        }
                    }
                }
            }
            return true
        }
    }
}

@MainActor
public final class CompilerAppDelegate: NSObject, NSApplicationDelegate {
    public weak var appState: AppState?
    public var pendingOpenPaths: [String] = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.module.resourceURL?.appendingPathComponent("Resources/AppIcon.icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        if let appState {
            for p in paths {
                appState.openExternalPath(p)
            }
        } else {
            pendingOpenPaths.append(contentsOf: paths)
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let ws = appState?.activeWorkspace {
            guard ws.confirmCloseIfNeeded() else {
                return .terminateCancel
            }
            ws.teardown()
        }
        return .terminateNow
    }
}
