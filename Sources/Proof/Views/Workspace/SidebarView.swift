import ProofCore
import SwiftUI

extension FileEntry {
    /// `OutlineGroup` needs optional children (nil = leaf).
    var outlineChildren: [FileEntry]? { isDirectory ? children : nil }
}

struct SidebarView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var filter = ""

    private var selection: Binding<String?> {
        Binding(
            get: { viewModel.currentFile },
            set: { path in
                // Folders only expand; a cancelled save prompt leaves `currentFile` unchanged, so the row reverts.
                guard let path, !viewModel.isDirectory(path) else { return }
                viewModel.openFile(path)
            }
        )
    }

    private var filteredFiles: [String] {
        FileService.fuzzyFilter(query: filter, files: viewModel.flatFiles, rootFolder: viewModel.folder)
    }

    var body: some View {
        Group {
            if viewModel.treeEntries.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "doc")
                } description: {
                    Text("Create a file to get started.")
                } actions: {
                    Button("New File…") { viewModel.createNewFile() }
                    Button("New Folder…") { viewModel.createNewFolder() }
                }
            } else {
                list
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter Files")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Menu {
                        Button("New File…") { viewModel.createNewFile() }
                        Button("New Folder…") { viewModel.createNewFolder() }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New File or Folder")
                    .accessibilityLabel("New")
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .background(.bar)
        }
    }

    private var list: some View {
        List(selection: selection) {
            Section("Files") {
                if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                    OutlineGroup(viewModel.treeEntries, children: \.outlineChildren) { entry in
                        row(for: entry)
                    }
                } else if filteredFiles.isEmpty {
                    Text("No files match “\(filter)”")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredFiles, id: \.self) { path in
                        Label((path as NSString).lastPathComponent, systemImage: Self.icon(forPath: path))
                            .lineLimit(1)
                            .help(viewModel.relativePath(path))
                            .tag(path)
                    }
                }
            }

            if viewModel.mode != .mermaid {
                Section("Outline") {
                    if viewModel.outlineHeadings.isEmpty {
                        Text("No Headings")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.outlineHeadings) { heading in
                            outlineRow(heading)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { paths in
            contextMenu(for: paths)
        } primaryAction: { paths in
            if let path = paths.first, !viewModel.isDirectory(path) { viewModel.openFile(path) }
        }
    }

    private func row(for entry: FileEntry) -> some View {
        Label(entry.name, systemImage: entry.isDirectory ? "folder" : Self.icon(forPath: entry.path))
            .lineLimit(1)
            .tag(entry.path)
    }

    private func outlineRow(_ heading: OutlineHeading) -> some View {
        let isActive = viewModel.activeOutlineLine == heading.line
        return Button {
            viewModel.revealLineInEditor(heading.line)
        } label: {
            Text(heading.title)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.leading, CGFloat(heading.depth) * 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isActive ? Color.accentColor.opacity(0.15) : nil)
        .help("Go to line \(heading.line)")
        .accessibilityLabel("\(heading.title), line \(heading.line)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private func contextMenu(for paths: Set<String>) -> some View {
        if let path = paths.first {
            if viewModel.isDirectory(path) {
                Button("New File…") { viewModel.createNewFile(in: path) }
                Button("New Folder…") { viewModel.createNewFolder(in: path) }
                Divider()
                Button("Show in Finder") { viewModel.revealInFinder(path) }
            } else {
                Button("Open") { viewModel.openFile(path) }
                if viewModel.mode == .latex, ["tex", "ltx"].contains((path as NSString).pathExtension.lowercased()) {
                    Button("Set as Main File") { viewModel.setAsMainFile(path) }
                }
                Button("Rename…") { viewModel.requestRename(path) }
                Button("Duplicate") { viewModel.duplicateFile(path) }
                Button("Show in Finder") { viewModel.revealInFinder(path) }
                Divider()
                Button("Move to Trash…", role: .destructive) { viewModel.requestTrash(path) }
            }
        } else {
            Button("New File…") { viewModel.createNewFile() }
            Button("New Folder…") { viewModel.createNewFolder() }
        }
    }

    static func icon(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "tex", "ltx": return "doc.text"
        case "bib": return "books.vertical"
        case "sty", "cls": return "gearshape"
        case "mmd", "mermaid": return "point.3.connected.trianglepath.dotted"
        case "md", "markdown": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "json": return "curlybraces"
        case "csv", "tsv", "xls", "xlsx": return "tablecells"
        case "yml", "yaml", "toml": return "list.bullet.indent"
        case "sh", "py", "lua", "js", "css", "html": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}
