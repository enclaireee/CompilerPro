import AppKit
import ProofCore
import CoreImage
import PDFKit
import SwiftUI

public struct NativePDFPreviewView: NSViewRepresentable {
    public let document: PDFDocument?
    public let invertColors: Bool
    public let syncTexSpots: [SyncTexSpot]
    public let syncTexTrigger: UUID
    public let zoomCommand: (id: UUID, command: PDFZoomCommand)?
    public let initialZoomMode: PDFZoomMode
    public let initialScale: CGFloat?
    public let onZoomChange: ((CGFloat, PDFZoomMode) -> Void)?
    public let onInverseSync: (Int, Double, Double) -> Void

    public init(
        document: PDFDocument?,
        invertColors: Bool,
        syncTexSpots: [SyncTexSpot],
        syncTexTrigger: UUID,
        zoomCommand: (id: UUID, command: PDFZoomCommand)? = nil,
        initialZoomMode: PDFZoomMode = .fitWidth,
        initialScale: CGFloat? = nil,
        onZoomChange: ((CGFloat, PDFZoomMode) -> Void)? = nil,
        onInverseSync: @escaping (Int, Double, Double) -> Void
    ) {
        self.document = document
        self.invertColors = invertColors
        self.syncTexSpots = syncTexSpots
        self.syncTexTrigger = syncTexTrigger
        self.zoomCommand = zoomCommand
        self.initialZoomMode = initialZoomMode
        self.initialScale = initialScale
        self.onZoomChange = onZoomChange
        self.onInverseSync = onInverseSync
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> SyncTexPDFView {
        let pdfView = SyncTexPDFView()
        pdfView.autoScales = false  // fit modes are computed by SyncTexPDFView
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.minScaleFactor = SyncTexPDFView.minScale
        pdfView.maxScaleFactor = SyncTexPDFView.maxScale
        pdfView.backgroundColor = NSColor.underPageBackgroundColor
        pdfView.wantsLayer = true
        pdfView.onInverseSync = onInverseSync
        pdfView.delegate = context.coordinator
        // Set mode before the callback so the initial value isn't reported back.
        pdfView.pendingScale = initialZoomMode == .custom ? initialScale : nil
        pdfView.zoomMode = initialZoomMode
        pdfView.onZoomChange = onZoomChange
        // A recreated view must not replay a command the VM already issued.
        context.coordinator.lastCommandID = zoomCommand?.id
        return pdfView
    }

    public func updateNSView(_ pdfView: SyncTexPDFView, context: Context) {
        pdfView.onInverseSync = onInverseSync
        pdfView.onZoomChange = onZoomChange

        if pdfView.document !== document {
            pdfView.replaceDocument(document)
        }

        if context.coordinator.lastInvert != invertColors {
            context.coordinator.lastInvert = invertColors
            applyColorFilter(to: pdfView, invert: invertColors)
        }

        if context.coordinator.lastSyncTrigger != syncTexTrigger, !syncTexSpots.isEmpty {
            context.coordinator.lastSyncTrigger = syncTexTrigger
            pdfView.flashSyncTexSpots(syncTexSpots)
        }

        if let cmd = zoomCommand, cmd.id != context.coordinator.lastCommandID {
            context.coordinator.lastCommandID = cmd.id
            pdfView.apply(cmd.command)
        }
    }

    private func applyColorFilter(to pdfView: PDFView, invert: Bool) {
        pdfView.wantsLayer = true
        if invert {
            let invertFilter = CIFilter(name: "CIColorInvert")
            let hueFilter = CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
            pdfView.layer?.filters = [invertFilter, hueFilter].compactMap { $0 }
        } else {
            pdfView.layer?.filters = nil
        }
    }

    public final class Coordinator: NSObject, PDFViewDelegate {
        public func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            // Only http(s)/mailto-style links per LinkPolicy; everything else is ignored.
            if let ok = LinkPolicy.externalURL(url.absoluteString) { NSWorkspace.shared.open(ok) }
        }
        var lastInvert: Bool?
        var lastSyncTrigger: UUID?
        var lastCommandID: UUID?
    }
}

// MARK: - SyncTeX-Aware Native PDFView Subclass

// SyncTeX convention: positions are PDF points from the TOP-LEFT of the page's
// MEDIA box (y down). PDFKit page space is user space (y up, origin = mediaBox
// origin, which may be non-zero); cropBox only affects what is displayed, so it
// is never used for SyncTeX conversion (only for fit-to-width/page sizing).

public final class SyncTexPDFView: PDFView {
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 8.0
    private static let fitMargin: CGFloat = 16

    var onInverseSync: ((Int, Double, Double) -> Void)?
    var onZoomChange: ((CGFloat, PDFZoomMode) -> Void)?
    var zoomMode: PDFZoomMode = .fitWidth {
        didSet { if oldValue != zoomMode { reportZoom() } }
    }
    private var activeAnnotations: [(PDFPage, PDFAnnotation)] = []
    private var clearWorkItem: DispatchWorkItem?
    private var expectedScale: CGFloat = 0
    private var lastFitSize: NSSize = .zero
    private var scaleObserver: NSObjectProtocol?
    private var isRestoring = false
    /// Scale to use for the first document when the mode is .custom (recreated view).
    var pendingScale: CGFloat?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setupObserver()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupObserver()
    }

    deinit {
        if let o = scaleObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func setupObserver() {
        scaleObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: self, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Scale differs from what we set => pinch / native gesture => custom.
            if abs(self.scaleFactor - self.expectedScale) > 0.0005 {
                self.expectedScale = self.scaleFactor
                if !self.isRestoring, self.zoomMode != .custom { self.zoomMode = .custom }
            }
            self.reportZoom()
        }
    }

    private func reportZoom() {
        let s = scaleFactor, m = zoomMode
        DispatchQueue.main.async { [weak self] in self?.onZoomChange?(s, m) }
    }

    // MARK: Zoom

    func apply(_ command: PDFZoomCommand) {
        switch command {
        case .zoomIn: setCustomScale(PDFZoomSteps.step(from: scaleFactor, zoomIn: true))
        case .zoomOut: setCustomScale(PDFZoomSteps.step(from: scaleFactor, zoomIn: false))
        case .set(let s): setCustomScale(s)
        case .fitWidth: zoomMode = .fitWidth; applyFit()
        case .fitPage: zoomMode = .fitPage; applyFit()
        case .actualSize:
            zoomMode = .actualSize
            setScale(1.0)
        }
    }

    private func setCustomScale(_ s: CGFloat, anchor: NSPoint? = nil) {
        zoomMode = .custom
        setScale(s, anchor: anchor)
    }

    private func setScale(_ s: CGFloat, anchor: NSPoint? = nil) {
        let clamped = min(max(s, Self.minScale), Self.maxScale)
        guard clamped.isFinite else { return }
        var anchorInfo: (PDFPage, NSPoint)?
        if let anchor, let page = page(for: anchor, nearest: true) {
            anchorInfo = (page, convert(anchor, to: page))
        }
        expectedScale = clamped
        autoScales = false
        scaleFactor = clamped
        if let anchor, let (page, pagePoint) = anchorInfo,
           let docView = documentView, let clip = docView.enclosingScrollView?.contentView {
            layoutDocumentView()
            let now = convert(pagePoint, from: page)
            let a = docView.convert(now, from: self), b = docView.convert(anchor, from: self)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x + a.x - b.x, y: clip.bounds.origin.y + a.y - b.y))
            docView.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        reportZoom()
    }

    private func applyFit() {
        guard zoomMode == .fitWidth || zoomMode == .fitPage,
              let doc = document, doc.pageCount > 0,
              let page = currentPage ?? doc.page(at: 0) else { return }
        lastFitSize = bounds.size
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let w = rotated ? box.height : box.width, h = rotated ? box.width : box.height
        let availW = bounds.width - 2 * Self.fitMargin
        let availH = bounds.height - 2 * Self.fitMargin
        guard w > 0, h > 0, availW > 0, availH > 0 else { return }
        setScale(zoomMode == .fitWidth ? availW / w : min(availW / w, availH / h))
    }

    public override func layout() {
        super.layout()
        if (zoomMode == .fitWidth || zoomMode == .fitPage), bounds.size != lastFitSize {
            applyFit()
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        let dy = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 4)
        guard dy != 0 else { return }
        let anchor = convert(event.locationInWindow, from: nil)
        setCustomScale(scaleFactor * exp(dy * 0.01), anchor: anchor)
    }

    public override func smartMagnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        if zoomMode == .fitWidth {
            setCustomScale(1.0, anchor: anchor)
        } else {
            apply(.fitWidth)
        }
    }

    // MARK: Document reload

    /// Swaps the document keeping page, in-page top-left position, scale and mode.
    func replaceDocument(_ newDoc: PDFDocument?) {
        // Corrupt / mid-write PDF: keep showing the old one.
        if let newDoc, newDoc.pageCount == 0, document != nil { return }

        var saved: (index: Int, point: NSPoint)?
        if let old = document, old.pageCount > 0 {
            let topLeft = NSPoint(x: bounds.minX, y: isFlipped ? bounds.minY : bounds.maxY)
            if let page = page(for: topLeft, nearest: true) {
                saved = (old.index(for: page), convert(topLeft, to: page))
            }
        }
        let scale = (document == nil ? pendingScale : nil) ?? scaleFactor, mode = zoomMode
        pendingScale = nil

        isRestoring = true
        document = newDoc
        guard let doc = newDoc, doc.pageCount > 0 else { isRestoring = false; return }

        let restore = { [weak self] in
            guard let self else { return }
            self.zoomMode = mode
            if mode == .fitWidth || mode == .fitPage {
                self.applyFit()
            } else {
                self.setScale(scale)
            }
            if let saved, let page = doc.page(at: min(saved.index, doc.pageCount - 1)) {
                self.go(to: PDFDestination(page: page, at: saved.point))
            }
        }
        restore()
        // PDFKit may not have laid out the new document yet; redo once next turn.
        DispatchQueue.main.async { [weak self] in
            if self?.document === doc { restore() }
            self?.isRestoring = false
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let isCommandClick = event.modifierFlags.contains(.command)
        let isDoubleClick = event.clickCount == 2

        if isCommandClick || isDoubleClick {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let page = page(for: viewPoint, nearest: true),
               let doc = document {
                let pagePoint = convert(viewPoint, to: page)
                let media = page.bounds(for: .mediaBox)
                let pageNumber = doc.index(for: page) + 1
                onInverseSync?(pageNumber, Double(pagePoint.x - media.minX), Double(media.maxY - pagePoint.y))
                return
            }
        }
        super.mouseDown(with: event)
    }

    func flashSyncTexSpots(_ spots: [SyncTexSpot]) {
        guard let doc = document else { return }
        clearActiveAnnotations()

        for (index, spot) in spots.enumerated() {
            let pageIdx = max(0, spot.page - 1)
            guard pageIdx < doc.pageCount, let page = doc.page(at: pageIdx) else { continue }
            let media = page.bounds(for: .mediaBox)
            let h = max(spot.h, 12)
            let pdfY = Double(media.maxY) - spot.y - h
            let rect = NSRect(x: Double(media.minX) + spot.x, y: pdfY, width: max(spot.w, 24), height: h)

            if index == 0 {
                let dest = PDFDestination(page: page, at: NSPoint(x: rect.minX, y: min(media.maxY, rect.maxY + 80)))
                go(to: dest)
            }

            let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            annotation.color = NSColor.systemYellow.withAlphaComponent(0.75)
            annotation.interiorColor = NSColor.systemYellow.withAlphaComponent(0.35)
            page.addAnnotation(annotation)
            activeAnnotations.append((page, annotation))
        }

        let work = DispatchWorkItem { [weak self] in
            self?.clearActiveAnnotations()
        }
        clearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func clearActiveAnnotations() {
        clearWorkItem?.cancel()
        for (page, annotation) in activeAnnotations {
            page.removeAnnotation(annotation)
        }
        activeAnnotations.removeAll()
    }
}
