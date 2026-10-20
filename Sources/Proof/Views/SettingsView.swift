import AppKit
import ProofCore
import SwiftUI

/// Shared by Welcome and Settings.
struct TexStatusRow: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if appState.texFound {
            Label {
                HStack(spacing: 6) {
                    Text("LaTeX is ready")
                    if let path = appState.texPath {
                        Text(path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("LaTeX isn't installed. You can still write and preview math; install MacTeX to build PDFs.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                HStack {
                    if let url = URL(string: "https://www.tug.org/mactex/") {
                        Link("Get MacTeX", destination: url)
                    }
                    Button("Check Again") { appState.recheckTex() }
                }
            }
            .font(.callout)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var updates = UpdateController.shared

    @AppStorage(AppSettings.appearance) private var appearance = AppThemePreference.auto.rawValue
    @AppStorage(AppSettings.restoreSession) private var restoreSession = true
    @AppStorage(AppSettings.editorFontSize) private var fontSize = 13.0
    @AppStorage(AppSettings.showLineNumbers) private var showLineNumbers = true
    @AppStorage(AppSettings.wrapLines) private var wrapLines = true
    @AppStorage(AppSettings.texEngine) private var texEngine = "auto"
    @AppStorage(AppSettings.texPath) private var texPath = ""
    @AppStorage(AppSettings.compileOnSave) private var compileOnSave = true
    @AppStorage(AppSettings.darkPDF) private var darkPDF = false
    @AppStorage(AppSettings.pdfZoomMode) private var zoomMode = "fitWidth"
    @AppStorage(AppSettings.autoCheckUpdates) private var autoCheckUpdates = true

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppThemePreference.allCases, id: \.rawValue) { p in
                        Text(p == .auto ? "System" : p.label).tag(p.rawValue)
                    }
                }
                Toggle("Reopen last project on launch", isOn: $restoreSession)
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Stepper(value: $fontSize, in: 10...24, step: 1) {
                    Text("Font size: \(Int(fontSize)) pt")
                }
                Text("The quick brown fox jumps over the lazy dog")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Toggle("Show line numbers", isOn: $showLineNumbers)
                Toggle("Wrap long lines", isOn: $wrapLines)
            }
            .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }

            Form {
                Section {
                    TexStatusRow(appState: appState)
                    HStack {
                        Button("Choose TeX Folder…", action: chooseTexFolder)
                        if !texPath.isEmpty {
                            Button("Use Automatic") {
                                texPath = ""
                                appState.recheckTex()
                            }
                        }
                    }
                }
                Picker("Engine", selection: $texEngine) {
                    Text("Automatic (from document)").tag("auto")
                    Text("pdfLaTeX").tag("pdflatex")
                    Text("XeLaTeX").tag("xelatex")
                    Text("LuaLaTeX").tag("lualatex")
                }
                Toggle("Compile automatically when saving", isOn: $compileOnSave)
                Toggle("Dark PDF pages in dark mode", isOn: $darkPDF)
                Picker("Default PDF zoom", selection: $zoomMode) {
                    Text("Fit Width").tag("fitWidth")
                    Text("Fit Page").tag("fitPage")
                    Text("Actual Size").tag("actualSize")
                }
            }
            .tabItem { Label("LaTeX", systemImage: "function") }

            Form {
                Section {
                    LabeledContent("Version", value: updates.currentVersion)
                    LabeledContent("Last checked", value: lastCheckedText)
                    HStack {
                        Button("Check Now") { updates.checkForUpdates() }
                            .disabled(updates.isChecking)
                        if updates.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                }
                Section {
                    Toggle("Check for updates automatically", isOn: $autoCheckUpdates)
                    Text("Proof checks GitHub once a day at launch and tells you when a newer version is available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Link("All Releases", destination: UpdateController.releasesURL)
                }
            }
            .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private var lastCheckedText: String {
        guard let date = updates.lastChecked else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func chooseTexFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose TeX Folder"
        panel.message = "Choose the folder that contains latexmk, for example /Library/TeX/texbin."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            texPath = url.path
            appState.recheckTex()
        }
    }
}
