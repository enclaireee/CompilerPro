import AppKit
import CompilerProCore
import SwiftUI

public struct WelcomeView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("CompilerPro").font(.largeTitle.bold())
            Text("Write LaTeX, Mermaid and Markdown — with live preview, fully offline.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button { appState.showNewProjectSheet = true } label: {
                    Label("New Project…", systemImage: "plus").frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .help("Create a new project (⌘N)")
                Button { appState.openPanel() } label: {
                    Label("Open…", systemImage: "folder").frame(minWidth: 130)
                }
                .buttonStyle(.bordered)
                .help("Open a project folder or file (⌘O)")
            }
            .controlSize(.large)
            .padding(.top, 4)

            recents
                .frame(maxWidth: 480)

            TexStatusRow(appState: appState)
                .frame(maxWidth: 480, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var recents: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent").font(.headline)
            if appState.recents.isEmpty {
                Text("Projects you open will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(appState.recents) { recent in
                    RecentRow(recent: recent, appState: appState)
                }
                .listStyle(.inset)
                .frame(height: min(CGFloat(appState.recents.count), 6) * 44 + 8)
            }
        }
    }
}

private struct RecentRow: View {
    let recent: RecentProject
    let appState: AppState

    var body: some View {
        Button { appState.openRecent(recent) } label: {
            HStack(spacing: 10) {
                Image(systemName: recent.mode.symbolName)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recent.displayLabel).lineLimit(1)
                    Text(recent.abbreviatedFolder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { appState.openRecent(recent) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recent.folder)])
            }
            Divider()
            Button("Remove from Recents") { appState.removeRecent(recent) }
        }
    }
}
