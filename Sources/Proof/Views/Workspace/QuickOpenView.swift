import SwiftUI

struct QuickOpenView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool

    var body: some View {
        let hits = viewModel.quickOpenHits
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Open Quickly", text: $viewModel.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($queryFocused)
                    .onSubmit { open(hits) }
                    .onKeyPress(.upArrow) { move(-1, count: hits.count); return .handled }
                    .onKeyPress(.downArrow) { move(1, count: hits.count); return .handled }
            }
            .padding(12)

            Divider()

            if hits.isEmpty {
                ContentUnavailableView.search(text: viewModel.quickOpenQuery)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(hits.enumerated()), id: \.element) { index, path in
                            row(path, selected: index == viewModel.quickOpenSelection)
                                .id(path)
                        }
                    }
                    .listStyle(.plain)
                    .frame(height: 280)
                    .onChange(of: viewModel.quickOpenSelection) { _, newValue in
                        if hits.indices.contains(newValue) {
                            proxy.scrollTo(hits[newValue])
                            AccessibilityNotification.Announcement((hits[newValue] as NSString).lastPathComponent).post()
                        }
                    }
                }
            }
        }
        .frame(width: 520)
        .onAppear { queryFocused = true }
        .onChange(of: viewModel.quickOpenQuery) { _, _ in viewModel.quickOpenSelection = 0 }
        .onExitCommand { dismiss() }
        .background(
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private func row(_ path: String, selected: Bool) -> some View {
        let dir = (viewModel.relativePath(path) as NSString).deletingLastPathComponent
        return Button {
            choose(path)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: viewModel.mode.symbolName)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .accessibilityHidden(true)
                Text((path as NSString).lastPathComponent)
                    .fontWeight(.semibold)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                if !dir.isEmpty && dir != "." {
                    Text(dir)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor) : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        viewModel.quickOpenSelection = min(max(0, viewModel.quickOpenSelection + delta), count - 1)
    }

    private func open(_ hits: [String]) {
        guard hits.indices.contains(viewModel.quickOpenSelection) else { return }
        choose(hits[viewModel.quickOpenSelection])
    }

    private func choose(_ path: String) {
        dismiss()
        viewModel.openFile(path)
    }
}
