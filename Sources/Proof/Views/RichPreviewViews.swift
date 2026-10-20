import AppKit
import ProofCore
import SwiftUI
import WebKit

// MARK: - Bundled Offline Web Assets (KaTeX, Mermaid 12, markdown-it)

@MainActor
private enum BundledWebAssets {
    static let resourcesURL: URL? = {
        Bundle.module.resourceURL?.appendingPathComponent("Resources", isDirectory: true)
    }()

    static let katexJS: String = loadResource("katex.min.js")
    static let mermaidJS: String = loadResource("mermaid.min.js")
    static let markdownItJS: String = loadResource("markdown-it.umd.min.js")

    static let katexCSSWithEmbeddedFonts: String = {
        var css = loadResource("katex.min.css")
        guard let fontsDir = resourcesURL?.appendingPathComponent("fonts", isDirectory: true) else {
            return css
        }
        // Remove legacy .woff and .ttf fallbacks and inline .woff2 as base64 data URIs so fonts work in any WKWebView context
        css = css.replacingOccurrences(
            of: #",url\(fonts/[^)]+\.woff\) format\("woff"\),url\(fonts/[^)]+\.ttf\) format\("truetype"\)"#,
            with: "",
            options: .regularExpression
        )
        let pattern = #"url\(fonts/([^)]+\.woff2)\)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(css.startIndex..<css.endIndex, in: css)
            let matches = regex.matches(in: css, range: nsRange).reversed()
            for match in matches {
                guard match.numberOfRanges >= 2,
                      let fileRange = Range(match.range(at: 1), in: css),
                      let fullRange = Range(match.range(at: 0), in: css) else { continue }
                let fileName = String(css[fileRange])
                let fileURL = fontsDir.appendingPathComponent(fileName)
                if let data = try? Data(contentsOf: fileURL) {
                    let b64 = data.base64EncodedString()
                    css.replaceSubrange(fullRange, with: "url(data:font/woff2;base64,\(b64))")
                }
            }
        }
        return css
    }()

    static let katexUserScript: WKUserScript = {
        WKUserScript(source: katexJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    static let mermaidUserScript: WKUserScript = {
        WKUserScript(source: mermaidJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    static let markdownItUserScript: WKUserScript = {
        WKUserScript(source: markdownItJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    private static func loadResource(_ name: String) -> String {
        guard let url = resourcesURL?.appendingPathComponent(name),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return content
    }
}

// MARK: - Shared hardened WKWebView plumbing

/// Forwards script messages so the user content controller never retains the coordinator.
@MainActor
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Base coordinator for the preview web views: builds a hardened WKWebView, allows only the
/// page load it starts itself and cancels every other navigation (link clicks are routed to `linkActivated`).
@MainActor
class WebPreviewCoordinator: NSObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    private(set) var isLoaded = false
    private var allowsNextLoad = false

    func makeWebView(userScripts: [WKUserScript], messageHandlerName: String? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        userScripts.forEach(config.userContentController.addUserScript)
        if let messageHandlerName, let handler = self as? WKScriptMessageHandler {
            config.userContentController.add(WeakScriptMessageProxy(handler), name: messageHandlerName)
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        self.webView = webView
        return webView
    }

    func load(html: String, baseURL: URL?) {
        isLoaded = false
        allowsNextLoad = true
        webView?.loadHTMLString(html, baseURL: baseURL)
    }

    func teardown() {
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Called after the host page finished loading.
    func didLoad() {}

    /// Called for a user-activated link that reached WebKit's navigation (the navigation itself is always cancelled).
    func linkActivated(_ url: URL) {}

    /// CSP for every host page: only our nonce-tagged inline script runs, so injected inline
    /// handlers, javascript: URLs, frames, objects and forms are refused even if markup slips through.
    static func contentSecurityPolicyMeta(nonce: String) -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'nonce-\(nonce)' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data: blob: file:; media-src data: blob: file:; font-src data:; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'\">"
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if allowsNextLoad && navigationAction.navigationType == .other {
            allowsNextLoad = false
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            linkActivated(url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        didLoad()
    }
}

// MARK: - 1. LaTeX Math Snippet Preview (No \documentclass — Powered by KaTeX)

public struct LatexSnippetPreviewView: View {
    public let sourceText: String

    public init(sourceText: String) {
        self.sourceText = sourceText
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "function")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Snippet Mode — No \\documentclass detected. Rendering live with KaTeX. Add \\documentclass for full PDF + SyncTeX.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.bar)

            Divider()

            LatexSnippetWebCanvas( blocks: TexService.mathBlocks(text: sourceText) )
        }
    }
}

private struct LatexSnippetWebCanvas: NSViewRepresentable {
    let blocks: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView(userScripts: [BundledWebAssets.katexUserScript])
        context.coordinator.pendingBlocks = blocks
        context.coordinator.loadInitialHTML()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(blocks: blocks)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: WebPreviewCoordinator {
        var pendingBlocks: [String] = []

        func loadInitialHTML() {
            let nonce = UUID().uuidString
            let html = #"""
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            \#(Self.contentSecurityPolicyMeta(nonce: nonce))
            <style>
              \#(BundledWebAssets.katexCSSWithEmbeddedFonts)
              :root { color-scheme: light dark; }
              body {
                margin: 0; padding: 24px;
                background: transparent;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                display: flex; justify-content: center;
              }
              .sheet {
                width: 100%; max-width: 720px; min-height: 260px;
                background: #ffffff; color: #1d1d1f;
                border-radius: 8px;
                padding: 28px 36px;
                box-shadow: 0 2px 12px rgba(0,0,0,0.08), 0 0 0 1px rgba(0,0,0,0.06);
              }
              @media (prefers-color-scheme: dark) {
                .sheet {
                  background: #1e1e20; color: #f5f5f7;
                  box-shadow: 0 4px 18px rgba(0,0,0,0.35), 0 0 0 1px rgba(255,255,255,0.08);
                }
              }
              .math-block {
                padding: 14px 0;
                border-bottom: 1px solid rgba(128,128,136,0.16);
                overflow-x: auto;
              }
              .math-block:last-child { border-bottom: none; }
              .empty {
                color: #8e8e93; font-size: 13px; text-align: center; padding: 48px 0;
              }
            </style>
            </head>
            <body>
              <div class="sheet" id="sheet"></div>
              <script nonce="\#(nonce)">
                window.renderBlocks = (blocks) => {
                  const sheet = document.getElementById("sheet");
                  if (!blocks || !blocks.length) {
                    sheet.innerHTML = '<div class="empty">Write LaTeX math expressions on the left to preview them live.</div>';
                    return;
                  }
                  sheet.replaceChildren(...blocks.map(src => {
                    const block = document.createElement("div");
                    block.className = "math-block";
                    try {
                      block.innerHTML = window.katex.renderToString(src, { displayMode: true, throwOnError: false, trust: false });
                    } catch (e) {
                      const code = document.createElement("code");
                      code.textContent = src;
                      block.replaceChildren(code);
                    }
                    return block;
                  }));
                };
              </script>
            </body>
            </html>
            """#
            load(html: html, baseURL: BundledWebAssets.resourcesURL)
        }

        override func didLoad() {
            renderNow(blocks: pendingBlocks)
        }

        func update(blocks: [String]) {
            guard blocks != pendingBlocks else { return }
            pendingBlocks = blocks
            guard isLoaded else { return }
            renderNow(blocks: blocks)
        }

        private func renderNow(blocks: [String]) {
            guard let webView,
                  let data = try? JSONEncoder().encode(blocks),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.renderBlocks(\(json));", completionHandler: nil)
        }
    }
}

// MARK: - 2. Mermaid Interactive Native Canvas (Powered by Bundled Mermaid 12 Engine)

public struct MermaidPreviewView: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    public init(viewModel: WorkspaceViewModel) {
        self.viewModel = viewModel
    }

    private var isEmpty: Bool {
        viewModel.editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            if isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Type a Mermaid diagram on the left to preview it live.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                MermaidWebCanvas(
                    code: viewModel.editorText,
                    zoom: $viewModel.mermaidZoom,
                    pan: $viewModel.mermaidPan,
                    errorMessage: $viewModel.mermaidError,
                    exportRequest: viewModel.mermaidExportRequest,
                    onExportCompleted: { msg, isErr in
                        viewModel.showToast(msg, isError: isErr)
                    }
                )
            }

            if let err = viewModel.mermaidError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.red)
                        .lineLimit(5)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
                )
                .padding(14)
            }
        }
        // The canvas only exists for non-empty text, so an export of an empty diagram is answered here.
        .onChange(of: viewModel.mermaidExportRequest?.id) { _, newID in
            guard newID != nil, isEmpty else { return }
            viewModel.showToast("Export failed: the diagram is empty", isError: true)
        }
    }
}

struct MermaidWebCanvas: NSViewRepresentable {
    typealias ExportRequest = (id: UUID, format: String, destPath: String, whiteBg: Bool)

    let code: String
    @Binding var zoom: Double
    @Binding var pan: CGSize
    @Binding var errorMessage: String?
    let exportRequest: ExportRequest?
    let onExportCompleted: (String, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let webView = coordinator.makeWebView(userScripts: [BundledWebAssets.mermaidUserScript], messageHandlerName: "mermaidBridge")
        // A request issued before this canvas existed (e.g. while the diagram was empty) is not replayed.
        coordinator.lastExportID = exportRequest?.id
        coordinator.loadInitialHTML()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.syncViewAndCode()
        if let req = exportRequest, req.id != coordinator.lastExportID {
            coordinator.lastExportID = req.id
            coordinator.performExport(req)
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: WebPreviewCoordinator, WKScriptMessageHandler {
        var parent: MermaidWebCanvas
        var lastExportID: UUID?
        private var lastCode = ""
        private var lastZoom = 1.0
        private var lastPan = CGSize.zero
        private var queuedExport: ExportRequest?
        private var debounceWork: DispatchWorkItem?

        init(_ parent: MermaidWebCanvas) {
            self.parent = parent
        }

        func loadInitialHTML() {
            load(html: Self.buildMermaidHostHTML(nonce: UUID().uuidString), baseURL: BundledWebAssets.resourcesURL)
        }

        override func didLoad() {
            lastZoom = parent.zoom
            lastPan = parent.pan
            webView?.evaluateJavaScript("window.setView(\(lastZoom), \(lastPan.width), \(lastPan.height));", completionHandler: nil)
            lastCode = parent.code
            renderNow(code: lastCode)
            if let req = queuedExport {
                queuedExport = nil
                performExport(req)
            }
        }

        /// Pushes Swift-side zoom/pan/code changes into the page. A changed pan binding is an explicit
        /// placement (reset / fit / new file); a zoom-only change keeps the pan and zooms around the centre.
        func syncViewAndCode() {
            guard isLoaded else { return }
            if parent.pan != lastPan {
                lastPan = parent.pan
                lastZoom = parent.zoom
                webView?.evaluateJavaScript("window.setView(\(lastZoom), \(lastPan.width), \(lastPan.height));", completionHandler: nil)
            } else if abs(parent.zoom - lastZoom) > 0.0001 {
                lastZoom = parent.zoom
                webView?.evaluateJavaScript("window.zoomTo(\(lastZoom));", completionHandler: nil)
            }
            guard parent.code != lastCode else { return }
            lastCode = parent.code
            debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.debounceWork = nil
                self.renderNow(code: self.lastCode)
            }
            debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private func renderNow(code: String) {
            guard let webView else { return }
            let encoded = (try? JSONEncoder().encode(code)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            webView.evaluateJavaScript("window.renderDiagram(\(encoded));", completionHandler: nil)
        }

        func performExport(_ req: ExportRequest) {
            guard isLoaded, let webView else {
                queuedExport = req
                return
            }
            // Export what the editor currently shows, not the pre-debounce diagram.
            if let pending = debounceWork {
                pending.cancel()
                debounceWork = nil
                renderNow(code: lastCode)
            }
            let call = req.format == "svg" ? "return await window.exportSVG(whiteBg);" : "return await window.exportPNGBase64(whiteBg);"
            webView.callAsyncJavaScript(call, arguments: ["whiteBg": req.whiteBg], in: nil, in: .page) { [weak self] result in
                guard let self else { return }
                guard case .success(let value) = result, let payload = value as? String, !payload.isEmpty else {
                    self.parent.onExportCompleted("Export failed: no rendered diagram", true)
                    return
                }
                do {
                    if req.format == "svg" {
                        try FileService.atomicWriteText(path: req.destPath, contents: payload)
                    } else {
                        guard let data = Data(base64Encoded: payload) else {
                            self.parent.onExportCompleted("PNG export failed", true)
                            return
                        }
                        try FileService.atomicWrite(path: req.destPath, data: data)
                    }
                    self.parent.onExportCompleted("Exported \((req.destPath as NSString).lastPathComponent)", false)
                } catch {
                    self.parent.onExportCompleted("Export failed: \(error.localizedDescription)", true)
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            if let err = dict["error"] as? String {
                parent.errorMessage = err.isEmpty ? nil : err
            }
            if let z = dict["zoom"] as? Double, let x = dict["panX"] as? Double, let y = dict["panY"] as? Double,
               z.isFinite, x.isFinite, y.isFinite {
                lastZoom = min(6, max(0.2, z))
                lastPan = CGSize(width: x, height: y)
                if parent.zoom != lastZoom { parent.zoom = lastZoom }
                if parent.pan != lastPan { parent.pan = lastPan }
            }
        }

        static func buildMermaidHostHTML(nonce: String) -> String {
            return #"""
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            \#(contentSecurityPolicyMeta(nonce: nonce))
            <style>
              :root { color-scheme: light dark; }
              html, body {
                margin: 0; width: 100%; height: 100%; overflow: hidden;
                background-color: transparent;
                background-image: radial-gradient(rgba(128,128,136,0.25) 1px, transparent 1px);
                background-size: 20px 20px;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                user-select: none; -webkit-user-select: none; cursor: grab;
              }
              body.panning { cursor: grabbing; }
              #stage {
                position: absolute; left: 0; top: 0; width: 100%; height: 100%;
                display: flex; align-items: center; justify-content: center;
                transform-origin: center center;
              }
              #stage svg {
                max-width: 92%; max-height: 92%;
                overflow: visible;
                filter: drop-shadow(0 2px 10px rgba(0,0,0,0.06));
              }
            </style>
            </head>
            <body>
            <div id="stage"></div>
            <script nonce="\#(nonce)">
              "use strict";
              const MIN_ZOOM = 0.2, MAX_ZOOM = 6;
              const stage = document.getElementById("stage");
              const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
              const bridge = (msg) => window.webkit?.messageHandlers?.mermaidBridge?.postMessage(msg);
              let currentScale = 1, panX = 0, panY = 0, lastSVG = "", lastCode = "", renderSeq = 0;
              let renderDone = Promise.resolve();

              function initMermaid() {
                if (!window.mermaid) return;
                window.mermaid.initialize({
                  startOnLoad: false,
                  securityLevel: "strict",
                  theme: darkQuery.matches ? "dark" : "default",
                  fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif'
                });
              }
              initMermaid();

              darkQuery.addEventListener("change", () => {
                initMermaid();
                if (lastCode) window.renderDiagram(lastCode);
              });

              function applyTransform() {
                stage.style.transform = `translate(${panX}px, ${panY}px) scale(${currentScale})`;
              }

              // Coalesce zoom/pan reports to Swift (timer, not rAF, so it also fires when occluded).
              let reportQueued = false;
              function reportView() {
                if (reportQueued) return;
                reportQueued = true;
                setTimeout(() => {
                  reportQueued = false;
                  bridge({ zoom: currentScale, panX, panY });
                }, 30);
              }

              // Zoom keeping the given viewport point fixed (defaults to the centre).
              function zoomAt(scale, clientX = window.innerWidth / 2, clientY = window.innerHeight / 2) {
                const next = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, scale));
                if (!isFinite(next)) return;
                const dx = clientX - window.innerWidth / 2, dy = clientY - window.innerHeight / 2;
                const k = next / currentScale;
                panX = dx - k * (dx - panX);
                panY = dy - k * (dy - panY);
                currentScale = next;
                applyTransform();
                reportView();
              }

              window.zoomTo = (z) => zoomAt(z);
              window.setView = (z, x, y) => {
                currentScale = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z));
                panX = x; panY = y;
                applyTransform();
              };

              window.exportSVG = async (whiteBg) => {
                await renderDone;
                if (!lastSVG) return "";
                if (!whiteBg) return lastSVG;
                return lastSVG.replace("<svg ", '<svg style="background:#ffffff" ');
              };

              // High-DPI 2x PNG via canvas rasterization; resolves to base64 or "" on failure.
              window.exportPNGBase64 = async (whiteBg) => {
                await renderDone;
                const svgEl = stage.querySelector("svg");
                if (!svgEl || !lastSVG) return "";
                const vb = svgEl.viewBox && svgEl.viewBox.baseVal && svgEl.viewBox.baseVal.width
                  ? svgEl.viewBox.baseVal
                  : svgEl.getBoundingClientRect();
                const w = Math.max(1, Math.ceil(vb.width || 800));
                const h = Math.max(1, Math.ceil(vb.height || 600));
                const scale = 2;
                let svgMarkup = lastSVG;
                if (!/xmlns=/.test(svgMarkup)) {
                  svgMarkup = svgMarkup.replace("<svg", '<svg xmlns="http://www.w3.org/2000/svg"');
                }
                return await new Promise((resolve) => {
                  const img = new Image();
                  img.onload = () => {
                    try {
                      const canvas = document.createElement("canvas");
                      canvas.width = w * scale;
                      canvas.height = h * scale;
                      const ctx = canvas.getContext("2d");
                      if (whiteBg) {
                        ctx.fillStyle = "#ffffff";
                        ctx.fillRect(0, 0, canvas.width, canvas.height);
                      }
                      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                      resolve(canvas.toDataURL("image/png").replace(/^data:image\/png;base64,/, ""));
                    } catch (e) { resolve(""); }
                  };
                  img.onerror = () => resolve("");
                  img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svgMarkup);
                });
              };

              let dragging = false, sx = 0, sy = 0;
              window.addEventListener("pointerdown", (e) => {
                if (e.button !== 0) return;
                dragging = true; sx = e.clientX - panX; sy = e.clientY - panY;
                document.body.setPointerCapture?.(e.pointerId);
                document.body.classList.add("panning");
              });
              window.addEventListener("pointermove", (e) => {
                if (!dragging) return;
                panX = e.clientX - sx; panY = e.clientY - sy; applyTransform();
              });
              const endDrag = () => {
                if (!dragging) return;
                dragging = false; document.body.classList.remove("panning");
                reportView();
              };
              window.addEventListener("pointerup", endDrag);
              window.addEventListener("pointercancel", endDrag);

              // Cmd-scroll (and ctrl-wheel) zooms at the pointer; plain scroll pans.
              let inGesture = false, gestureBaseScale = 1;
              window.addEventListener("wheel", (e) => {
                e.preventDefault();
                if (e.ctrlKey || e.metaKey) {
                  if (inGesture) return;
                  const dy = e.deltaY * (e.deltaMode === 1 ? 16 : 1);
                  zoomAt(currentScale * Math.exp(-Math.max(-40, Math.min(40, dy)) * 0.01), e.clientX, e.clientY);
                } else {
                  panX -= e.deltaX; panY -= e.deltaY;
                  applyTransform();
                  reportView();
                }
              }, { passive: false });

              // Trackpad pinch (WebKit gesture events), anchored at the pointer.
              window.addEventListener("gesturestart", (e) => {
                e.preventDefault(); inGesture = true; gestureBaseScale = currentScale;
              });
              window.addEventListener("gesturechange", (e) => {
                e.preventDefault();
                zoomAt(gestureBaseScale * e.scale, e.clientX, e.clientY);
              });
              window.addEventListener("gestureend", (e) => {
                e.preventDefault(); inGesture = false;
              });

              window.renderDiagram = (code) => {
                lastCode = code || "";
                const trimmed = lastCode.trim();
                const seq = ++renderSeq;
                if (!trimmed) {
                  stage.replaceChildren();
                  lastSVG = "";
                  bridge({ error: "" });
                  renderDone = Promise.resolve();
                  return renderDone;
                }
                renderDone = (async () => {
                  try {
                    const out = await window.mermaid.render("mmd-" + seq, trimmed);
                    if (seq !== renderSeq) return;
                    lastSVG = out.svg;
                    stage.innerHTML = out.svg;
                    bridge({ error: "" });
                  } catch (err) {
                    if (seq !== renderSeq) return;
                    bridge({ error: err && err.message ? err.message : String(err) });
                  }
                })();
                return renderDone;
              };
            </script>
            </body>
            </html>
            """#
        }
    }
}

// MARK: - 3. Native Markdown Live Preview (markdown-it + KaTeX + Inline Mermaid + Scroll Sync)

public struct MarkdownPreviewView: View {
    public let markdownText: String
    public let baseDirectory: String
    public let topLine: Int
    public let workspaceRoot: String?
    public let allowedExtensions: [String]
    public let onOpenRelativeMarkdown: (String) -> Void

    /// - Parameters:
    ///   - workspaceRoot: links may only open files inside this folder; defaults to `baseDirectory`.
    ///   - allowedExtensions: extensions a link may open (case-insensitive).
    ///   - onOpenRelativeMarkdown: receives an already validated, existing, absolute file path.
    public init(
        markdownText: String,
        baseDirectory: String,
        topLine: Int,
        workspaceRoot: String? = nil,
        allowedExtensions: [String] = WorkspaceMode.markdown.extensions,
        onOpenRelativeMarkdown: @escaping (String) -> Void
    ) {
        self.markdownText = markdownText
        self.baseDirectory = baseDirectory
        self.topLine = topLine
        self.workspaceRoot = workspaceRoot
        self.allowedExtensions = allowedExtensions
        self.onOpenRelativeMarkdown = onOpenRelativeMarkdown
    }

    public var body: some View {
        MarkdownWebCanvas(
            markdownText: markdownText,
            baseDirectory: baseDirectory,
            topLine: topLine,
            workspaceRoot: workspaceRoot ?? baseDirectory,
            allowedExtensions: allowedExtensions,
            onOpenRelativeMarkdown: onOpenRelativeMarkdown
        )
    }
}

private struct MarkdownWebCanvas: NSViewRepresentable {
    let markdownText: String
    let baseDirectory: String
    let topLine: Int
    let workspaceRoot: String
    let allowedExtensions: [String]
    let onOpenRelativeMarkdown: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView(
            userScripts: [BundledWebAssets.markdownItUserScript, BundledWebAssets.katexUserScript, BundledWebAssets.mermaidUserScript],
            messageHandlerName: "mdBridge"
        )
        context.coordinator.loadPage()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: WebPreviewCoordinator, WKScriptMessageHandler {
        var parent: MarkdownWebCanvas
        private var loadedBaseDirectory: String?
        private var lastMarkdown = ""
        private var lastTopLine = 1
        private var debounceWork: DispatchWorkItem?

        init(_ parent: MarkdownWebCanvas) {
            self.parent = parent
        }

        /// The base URL is the Markdown file's folder so relative images resolve; navigation stays blocked.
        func loadPage() {
            debounceWork?.cancel()
            loadedBaseDirectory = parent.baseDirectory
            load(
                html: Self.buildMarkdownHostHTML(nonce: UUID().uuidString),
                baseURL: URL(fileURLWithPath: parent.baseDirectory, isDirectory: true)
            )
        }

        override func didLoad() {
            lastMarkdown = parent.markdownText
            lastTopLine = parent.topLine
            renderNow(markdown: lastMarkdown)
            scrollToLineNow(lastTopLine)
        }

        func update() {
            if parent.baseDirectory != loadedBaseDirectory {
                loadPage()
                return
            }
            guard isLoaded else { return }
            if parent.markdownText != lastMarkdown {
                lastMarkdown = parent.markdownText
                debounceWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.renderNow(markdown: self.lastMarkdown)
                }
                debounceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
            if parent.topLine != lastTopLine {
                lastTopLine = parent.topLine
                scrollToLineNow(lastTopLine)
            }
        }

        private func renderNow(markdown: String) {
            guard let webView,
                  let data = try? JSONEncoder().encode(markdown),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.renderMarkdown(\(json));", completionHandler: nil)
        }

        private func scrollToLineNow(_ line: Int) {
            webView?.evaluateJavaScript("window.syncScrollToLine(\(line));", completionHandler: nil)
        }

        /// Single Swift-side gate for every link out of an untrusted document.
        private func follow(link: String) {
            if let url = LinkPolicy.externalURL(link) {
                NSWorkspace.shared.open(url)
            } else if let path = LinkPolicy.resolveWorkspaceFile(
                href: link,
                baseDirectory: parent.baseDirectory,
                workspaceRoot: parent.workspaceRoot,
                allowedExtensions: parent.allowedExtensions
            ) {
                parent.onOpenRelativeMarkdown(path)
            }
        }

        override func linkActivated(_ url: URL) {
            follow(link: url.absoluteString)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            if let rel = dict["openRelative"] as? String {
                follow(link: rel)
            } else if let ext = dict["openExternal"] as? String, let url = LinkPolicy.externalURL(ext) {
                NSWorkspace.shared.open(url)
            }
        }

        static func buildMarkdownHostHTML(nonce: String) -> String {
            return #"""
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            \#(contentSecurityPolicyMeta(nonce: nonce))
            <style>
              \#(BundledWebAssets.katexCSSWithEmbeddedFonts)
              :root {
                color-scheme: light dark;
                --fg: #1d1d1f;
                --fg-2: #6e6e73;
                --bg-code: rgba(0, 0, 0, 0.045);
                --border: rgba(0, 0, 0, 0.10);
                --accent: #007aff;
                --danger: #d70015;
              }
              @media (prefers-color-scheme: dark) {
                :root {
                  --fg: #f5f5f7;
                  --fg-2: #98989d;
                  --bg-code: rgba(255, 255, 255, 0.06);
                  --border: rgba(255, 255, 255, 0.12);
                  --accent: #0a84ff;
                  --danger: #ff453a;
                }
              }
              html, body {
                margin: 0; padding: 0;
                background: transparent;
                color: var(--fg);
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 15px; line-height: 1.65;
                -webkit-font-smoothing: antialiased;
              }
              #container {
                max-width: 720px;
                margin: 0 auto;
                padding: 28px 36px 88px;
              }
              h1, h2, h3, h4, h5, h6 {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
                font-weight: 600;
                line-height: 1.25;
                letter-spacing: -0.015em;
                margin: 1.5em 0 0.55em;
              }
              h1 { font-size: 1.85em; border-bottom: 1px solid var(--border); padding-bottom: 0.28em; margin-top: 0.2em; }
              h2 { font-size: 1.42em; border-bottom: 1px solid var(--border); padding-bottom: 0.22em; }
              h3 { font-size: 1.18em; }
              p, ul, ol, blockquote, table, pre { margin: 0 0 1em; }
              a { color: var(--accent); text-decoration: none; }
              a:hover { text-decoration: underline; }
              code {
                font-family: "SF Mono", ui-monospace, Menlo, monospace;
                font-size: 0.88em;
                background: var(--bg-code);
                padding: 2px 5px;
                border-radius: 5px;
              }
              pre {
                background: var(--bg-code);
                border: 1px solid var(--border);
                border-radius: 8px;
                padding: 12px 14px;
                overflow-x: auto;
              }
              pre code { background: none; padding: 0; font-size: 12.5px; }
              blockquote {
                margin-left: 0;
                padding: 4px 0 4px 14px;
                border-left: 3px solid var(--accent);
                color: var(--fg-2);
              }
              table {
                width: 100%;
                border-collapse: collapse;
                font-size: 14px;
              }
              th, td {
                border: 1px solid var(--border);
                padding: 7px 11px;
                text-align: left;
              }
              th { background: var(--bg-code); font-weight: 600; }
              hr { border: 0; border-top: 1px solid var(--border); margin: 24px 0; }
              img { max-width: 100%; border-radius: 6px; }
              li.task { list-style: none; margin-left: -1.2em; }
              .md-mermaid {
                display: flex; justify-content: center;
                padding: 14px; margin: 0 0 1em;
                background: var(--bg-code);
                border: 1px solid var(--border);
                border-radius: 8px;
                overflow-x: auto;
              }
              .md-mermaid.stale { opacity: 0.55; }
              .md-mermaid-error { color: var(--danger); background: none; border: 0; margin: 0; white-space: pre-wrap; }
              .katex-display { overflow-x: auto; overflow-y: hidden; padding: 4px 0; }
            </style>
            </head>
            <body>
            <div id="container"></div>
            <script nonce="\#(nonce)">
              "use strict";
              const container = document.getElementById("container");
              const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
              const bridge = (msg) => window.webkit?.messageHandlers?.mdBridge?.postMessage(msg);
              let md = null, renderSeq = 0, mmdSeq = 0, lastRaw = "";
              // theme + "\n" + diagram source -> rendered SVG markup (or a Promise while rendering).
              const mermaidCache = new Map();

              function esc(s) {
                return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
              }

              function ensureMarkdownIt() {
                if (md || !window.markdownit) return md;
                md = window.markdownit({ html: true, linkify: true, typographer: true });
                const defaultFence = md.renderer.rules.fence || function(tokens, idx, options, env, self) {
                  return self.renderToken(tokens, idx, options);
                };
                md.renderer.rules.fence = (tokens, idx, options, env, self) => {
                  const token = tokens[idx];
                  const info = (token.info || "").trim().toLowerCase();
                  const lineAttr = token.map ? ` data-line="${token.map[0] + 1}"` : "";
                  if (info === "mermaid") {
                    const encoded = encodeURIComponent(token.content);
                    return `<div class="md-mermaid"${lineAttr} data-mermaid="${encoded}"></div>`;
                  }
                  return defaultFence(tokens, idx, options, env, self);
                };
                ["paragraph_open", "heading_open", "blockquote_open", "bullet_list_open", "ordered_list_open", "table_open", "hr"].forEach(rule => {
                  const orig = md.renderer.rules[rule] || function(tokens, idx, options, env, self) {
                    return self.renderToken(tokens, idx, options);
                  };
                  md.renderer.rules[rule] = function(tokens, idx, options, env, self) {
                    const token = tokens[idx];
                    if (token.map && token.map.length) {
                      token.attrSet("data-line", String(token.map[0] + 1));
                    }
                    return orig(tokens, idx, options, env, self);
                  };
                });
                return md;
              }

              // ---- Math. Code (``` / ~~~ fences, inline code spans) is stashed first so it is never
              // treated as math; math becomes private-use placeholders that markdown-it leaves alone
              // and that are swapped for KaTeX HTML after rendering.
              const stashToken = (kind, list, value) => "\uE000" + kind + (list.push(value) - 1) + "\uE001";

              function stashFences(src, code) {
                const out = [];
                let fence = null, buf = [];
                for (const line of src.split("\n")) {
                  if (fence) {
                    buf.push(line);
                    const close = line.match(/^ {0,3}(`{3,}|~{3,})[ \t]*$/);
                    if (close && close[1][0] === fence[0] && close[1].length >= fence.length) {
                      out.push(stashToken("C", code, buf.join("\n")));
                      fence = null; buf = [];
                    }
                    continue;
                  }
                  const open = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
                  if (open && !(open[1][0] === "`" && open[2].includes("`"))) {
                    fence = open[1]; buf = [line];
                    continue;
                  }
                  out.push(line);
                }
                if (fence) out.push(stashToken("C", code, buf.join("\n")));
                return out.join("\n");
              }

              function renderTex(tex, displayMode) {
                try {
                  return window.katex.renderToString(tex.trim(), { displayMode, throwOnError: false, trust: false });
                } catch (e) {
                  return `<code>${esc(tex)}</code>`;
                }
              }

              function extractMath(src, math) {
                const code = [];
                let text = stashFences(src, code);
                // Inline code spans: matching backtick runs, not across blank lines.
                text = text.replace(/(?<![`\\])(`+)(?!`)(?:[^\n]|\n(?![ \t]*\n))*?[^`\n]\1(?!`)/g, (m) => stashToken("C", code, m));
                // $$display$$ — keep the line count so data-line scroll sync stays aligned.
                text = text.replace(/(?<!\\)\$\$([\s\S]+?)(?<!\\)\$\$/g, (m, tex) =>
                  stashToken("M", math, renderTex(tex, true)) + "\n".repeat((m.match(/\n/g) || []).length));
                // Pandoc inline rule: opening $ not followed by whitespace, closing $ not preceded by
                // whitespace and not followed by a digit (so "$5 and $10" stays text). \$ is literal.
                text = text.replace(/(?<![\\$])\$(?![\s$])((?:[^$\\\n]|\\[\s\S]|\n(?![ \t]*\n))+?)(?<![\s\\])\$(?!\d)/g, (m, tex) =>
                  stashToken("M", math, renderTex(tex, false)));
                return text.replace(/\uE000C(\d+)\uE001/g, (_, i) => code[Number(i)]);
              }

              function buildHTML(raw) {
                const math = [];
                const src = window.katex ? extractMath(raw, math) : raw;
                const parser = ensureMarkdownIt();
                const html = (parser ? parser.render(src) : `<pre>${esc(src)}</pre>`)
                  .replace(/<li>\s*\[ \]\s*/g, '<li class="task"><input type="checkbox" disabled> ')
                  .replace(/<li>\s*\[[xX]\]\s*/g, '<li class="task"><input type="checkbox" checked disabled> ');
                return html.replace(/\uE000M(\d+)\uE001/g, (_, i) => math[Number(i)] ?? "");
              }

              // ---- Sanitizer for raw HTML in documents. Parsed into an inert document (nothing loads
              // or runs there), cleaned, then the nodes are moved in directly (no re-serialisation).
              const BLOCKED_TAGS = new Set(["script", "iframe", "frame", "frameset", "object", "embed", "applet",
                "base", "meta", "link", "style", "form", "template", "noscript", "portal",
                "set", "animate", "animatemotion", "animatetransform"]);
              const URL_ATTRS = new Set(["href", "xlink:href", "src", "srcset", "action", "formaction", "background",
                "poster", "data", "codebase", "cite", "longdesc", "lowsrc", "dynsrc", "values", "to", "from", "by"]);

              function sanitize(html) {
                const doc = new DOMParser().parseFromString("<!doctype html><body>" + html, "text/html");
                for (const el of doc.body.querySelectorAll("*")) {
                  const tag = el.localName.toLowerCase();
                  if (BLOCKED_TAGS.has(tag)) { el.remove(); continue; }
                  for (const { name, value } of Array.from(el.attributes)) {
                    const n = name.toLowerCase();
                    const v = value.replace(/[\u0000-\u0020\u007F-\u00A0\u1680\u180E\u2000-\u2029\u205F\u3000\uFEFF]/g, "").toLowerCase();
                    const dangerousURL = /^(javascript|vbscript|data):/.test(v) &&
                      !(tag === "img" && n === "src" && /^data:image\//.test(v));
                    if (n.startsWith("on") || n === "srcdoc" || (URL_ATTRS.has(n) && dangerousURL)) {
                      el.removeAttribute(name);
                    }
                  }
                }
                return doc.body;
              }

              // ---- Mermaid blocks: cached by theme + source, so only changed diagrams re-render.
              function initMermaid() {
                if (!window.mermaid) return;
                window.mermaid.initialize({
                  startOnLoad: false,
                  securityLevel: "strict",
                  theme: darkQuery.matches ? "dark" : "default"
                });
              }
              initMermaid();

              function renderMermaidSource(code) {
                return window.mermaid.render("md-mmd-" + (++mmdSeq), code).then(
                  (out) => out.svg,
                  (err) => `<pre class="md-mermaid-error">${esc(err && err.message ? err.message : err)}</pre>`
                );
              }

              function hydrateMermaid(seq, previous) {
                if (!window.mermaid) return;
                const theme = darkQuery.matches ? "dark" : "default";
                const used = new Set();
                container.querySelectorAll(".md-mermaid[data-mermaid]").forEach((node, i) => {
                  let code = "";
                  try { code = decodeURIComponent(node.getAttribute("data-mermaid") || "").trim(); } catch (e) {}
                  if (!code) return;
                  const key = theme + "\n" + code;
                  used.add(key);
                  let cached = mermaidCache.get(key);
                  if (typeof cached === "string") { node.innerHTML = cached; return; }
                  // Keep showing the previous diagram at this position (dimmed) while the new one renders.
                  if (previous[i]) { node.innerHTML = previous[i]; node.classList.add("stale"); }
                  if (!cached) {
                    cached = renderMermaidSource(code).then((svg) => {
                      if (mermaidCache.get(key) === cached) mermaidCache.set(key, svg);
                      return svg;
                    });
                    mermaidCache.set(key, cached);
                  }
                  cached.then((svg) => {
                    if (seq !== renderSeq) return; // a newer render owns the DOM now
                    node.innerHTML = svg;
                    node.classList.remove("stale");
                  });
                });
                for (const key of Array.from(mermaidCache.keys())) {
                  if (!used.has(key)) mermaidCache.delete(key);
                }
              }

              window.renderMarkdown = (raw) => {
                lastRaw = raw || "";
                const seq = ++renderSeq;
                const body = sanitize(buildHTML(lastRaw));
                const previous = Array.from(container.querySelectorAll(".md-mermaid[data-mermaid]"), (n) => n.innerHTML);
                const scrollY = window.scrollY;
                container.replaceChildren(...body.childNodes);
                hydrateMermaid(seq, previous);
                window.scrollTo(0, scrollY);
              };

              darkQuery.addEventListener("change", () => {
                initMermaid();
                window.renderMarkdown(lastRaw);
              });

              window.syncScrollToLine = (line) => {
                const els = Array.from(container.querySelectorAll("[data-line]"));
                if (!els.length) return;
                let target = els[0];
                for (const el of els) {
                  const l = parseInt(el.getAttribute("data-line") || "1", 10);
                  if (l <= line) target = el; else break;
                }
                target.scrollIntoView({ behavior: "smooth", block: "start" });
              };

              // Links never navigate this page; Swift validates and decides (see LinkPolicy).
              document.addEventListener("click", (e) => {
                const a = e.target && e.target.closest ? e.target.closest("a") : null;
                if (!a) return;
                e.preventDefault();
                const href = (a.getAttribute("href") || a.getAttributeNS("http://www.w3.org/1999/xlink", "href") || "").trim();
                if (!href) return;
                if (href.startsWith("#")) {
                  let id = href.slice(1);
                  try { id = decodeURIComponent(id); } catch (err) {}
                  const target = document.getElementById(id) || document.getElementsByName(id)[0];
                  if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
                  return;
                }
                if (/^(https?:\/\/|mailto:)/i.test(href)) {
                  bridge({ openExternal: href });
                } else if (/^file:/i.test(href) || !/^[a-z][a-z0-9+.\-]*:/i.test(href)) {
                  bridge({ openRelative: href });
                }
              });
            </script>
            </body>
            </html>
            """#
        }
    }
}
