import SwiftUI

/// Compact toolbar zoom control: [-] [125% v] [+].
public struct ZoomControl: View {
    public let scale: CGFloat
    public let onCommand: (PDFZoomCommand) -> Void
    public let showsFitModes: Bool

    public init(scale: CGFloat, onCommand: @escaping (PDFZoomCommand) -> Void, showsFitModes: Bool = true) {
        self.scale = scale
        self.onCommand = onCommand
        self.showsFitModes = showsFitModes
    }

    private var percent: String { "\(Int((scale * 100).rounded()))%" }

    public var body: some View {
        ControlGroup {
            Button { onCommand(.zoomOut) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom Out (⌘-)")
            .accessibilityLabel("Zoom Out")

            Menu {
                if showsFitModes {
                    Button("Fit Width") { onCommand(.fitWidth) }
                    Button("Fit Page") { onCommand(.fitPage) }
                    Button("Actual Size") { onCommand(.actualSize) }
                    Divider()
                }
                ForEach([50, 75, 100, 125, 150, 200, 400], id: \.self) { p in
                    Button("\(p)%") { onCommand(.set(CGFloat(p) / 100)) }
                }
            } label: {
                Text(percent).monospacedDigit()
            }
            .help("Zoom level")
            .accessibilityLabel("Zoom Level")
            .accessibilityValue(percent)

            Button { onCommand(.zoomIn) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom In (⌘=)")
            .accessibilityLabel("Zoom In")
        }
    }
}
