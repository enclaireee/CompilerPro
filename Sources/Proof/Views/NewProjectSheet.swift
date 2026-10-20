import AppKit
import ProofCore
import SwiftUI

struct NewProjectSheet: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var mode: WorkspaceMode = .latex
    @State private var name = NewProjectSheet.availableName()
    @State private var location = NewProjectSheet.defaultLocation

    private static var defaultLocation: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// "Untitled", or the first free "Untitled 2", "Untitled 3"… so Create is never dead on arrival.
    private static func availableName(in directory: URL = defaultLocation) -> String {
        let fileManager = FileManager.default
        var candidate = "Untitled"
        var counter = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "Untitled \(counter)"
            counter += 1
        }
        return candidate
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var exists: Bool {
        !trimmedName.isEmpty
            && FileManager.default.fileExists(atPath: location.appendingPathComponent(trimmedName).path)
    }
    private var invalid: Bool { trimmedName.isEmpty || trimmedName.contains("/") || trimmedName.hasPrefix(".") }

    private var problem: String? {
        if trimmedName.isEmpty { return "Enter a name for the project" }
        if trimmedName.contains("/") || trimmedName.hasPrefix(".") { return "Names can't contain \"/\" or start with a period" }
        if exists { return "A folder with this name already exists" }
        return nil
    }

    private static let blurbs: [WorkspaceMode: (String, String)] = [
        .latex: ("LaTeX Document", "Articles, reports and papers. Builds a PDF."),
        .mermaid: ("Mermaid Diagram", "Flowcharts, sequences and more."),
        .markdown: ("Markdown Notes", "Notes and docs with math and diagrams."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project").font(.title2.bold())

            HStack(alignment: .top, spacing: 12) {
                ForEach(WorkspaceMode.allCases) { m in
                    card(m)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Template")

            Form {
                TextField("Name", text: $name)
                LabeledContent("Location") {
                    HStack {
                        Text((location.path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseLocation)
                    }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    appState.createProject(mode: mode, name: trimmedName, in: location)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(invalid || exists)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func card(_ m: WorkspaceMode) -> some View {
        let selected = m == mode
        let text = Self.blurbs[m] ?? (m.displayName, m.subtitle)
        return Button { mode = m } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: m.symbolName)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                Text(text.0).font(.headline)
                Text(text.1).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text.0)
        .accessibilityHint(text.1)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = location
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { location = url }
    }
}
