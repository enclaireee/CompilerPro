import CoreGraphics

public enum PDFZoomMode: String, CaseIterable {
    case fitWidth, fitPage, actualSize, custom
}

public enum PDFZoomCommand: Equatable {
    case zoomIn, zoomOut, fitWidth, fitPage, actualSize
    /// Absolute scale (1.0 = 100%).
    case set(CGFloat)
}

enum PDFZoomSteps {
    static let nice: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5, 8]

    /// Next nice value above/below `scale`; falls back to x1.25 outside the table.
    static func step(from scale: CGFloat, zoomIn: Bool) -> CGFloat {
        if zoomIn {
            return nice.first { $0 > scale * 1.02 } ?? scale * 1.25
        }
        return nice.last { $0 < scale / 1.02 } ?? scale / 1.25
    }
}
