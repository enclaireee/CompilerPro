import AppKit
import ProofCore
import SwiftUI

/// Xcode-style welcome: actions on the left, recent projects in a sidebar column on the right.
public struct WelcomeView: View {
    @ObservedObject var appState: AppState
    @State private var selection: RecentProject.ID?

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 0) {
            hero
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            recents
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                .background(.background.secondary)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text("Proof")
                .font(.system(size: 34, weight: .bold))
                .padding(.top, 12)
            Text("LaTeX, Mermaid and Markdown. Live preview, fully offline.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            VStack(spacing: 4) {
                ActionRow(
                    title: "Create New Project…",
                    subtitle: "Start from a LaTeX, Mermaid or Markdown template",
                    symbol: "plus.square",
                    shortcut: "⌘N"
                ) { appState.showNewProjectSheet = true }
                ActionRow(
                    title: "Open Existing…",
                    subtitle: "A project folder, or a .tex, .mmd or .md file",
                    symbol: "folder",
                    shortcut: "⌘O"
                ) { appState.openPanel() }
            }
            .frame(maxWidth: 400)
            .padding(.top, 32)

            Spacer(minLength: 24)
            TexStatusRow(appState: appState)
                .frame(maxWidth: 400, alignment: .leading)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Recents

    @ViewBuilder private var recents: some View {
        if appState.recents.isEmpty {
            ContentUnavailableView(
                "No Recent Projects",
                systemImage: "clock",
                description: Text("Projects you open will appear here.")
            )
        } else {
            List(appState.recents, selection: $selection) { recent in
                RecentRow(recent: recent)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("Recent Projects")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 4)
            }
            // Native list behaviour: click selects, double-click or Return opens.
            .contextMenu(forSelectionType: RecentProject.ID.self) { ids in
                if let recent = recent(for: ids) {
                    Button("Open") { appState.openRecent(recent) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recent.folder)])
                    }
                    Divider()
                    Button("Remove from Recents") { appState.removeRecent(recent) }
                }
            } primaryAction: { ids in
                if let recent = recent(for: ids) { appState.openRecent(recent) }
            }
        }
    }

    private func recent(for ids: Set<RecentProject.ID>) -> RecentProject? {
        guard let id = ids.first else { return nil }
        return appState.recents.first { $0.id == id }
    }
}

// MARK: - Rows

private struct ActionRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(shortcut)
                    .font(.callout.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct RecentRow: View {
    let recent: RecentProject

    private var folderName: String { (recent.folder as NSString).lastPathComponent }
    private var detail: String {
        if let file = recent.file, !file.isEmpty {
            return (file as NSString).lastPathComponent
        }
        return recent.abbreviatedFolder
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recent.mode.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(recent.mode.tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(recent.mode.displayName)
            VStack(alignment: .leading, spacing: 1) {
                Text(folderName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(Date(timeIntervalSince1970: recent.timestamp), format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .help(recent.abbreviatedFolder)
    }
}

private extension WorkspaceMode {
    var tint: Color {
        switch self {
        case .latex: .teal
        case .mermaid: .pink
        case .markdown: .indigo
        }
    }
}
