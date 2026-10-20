import ProofCore
import Foundation

/// UserDefaults keys shared by Settings and the views that read them via `@AppStorage`.
public enum AppSettings {
    public static let appearance = "cp.appearance"          // AppThemePreference.rawValue
    public static let editorFontSize = "cp.editorFontSize"  // Double, default 13
    public static let showLineNumbers = "cp.showLineNumbers" // Bool, default true
    public static let wrapLines = "cp.wrapLines"            // Bool, default true
    public static let texEngine = "cp.texEngine"            // "auto" | "pdflatex" | "xelatex" | "lualatex"
    public static let texPath = "cp.texPath"                // String, empty = auto-detect
    public static let compileOnSave = "cp.compileOnSave"    // Bool, default true
    public static let darkPDF = "cp.darkPDF"                // Bool, default false
    public static let pdfZoomMode = "cp.pdfZoomMode"        // "fitWidth" | "fitPage" | "actualSize"
    public static let restoreSession = "cp.restoreSession"  // Bool, default true

    // Update check: on by default, at most once a day.
    public static let autoCheckUpdates = "cp.autoCheckUpdates"          // Bool, default true
    public static let lastUpdateCheck = "cp.lastUpdateCheck"            // Date of the last completed check
    public static let offeredUpdateVersion = "cp.offeredUpdateVersion"  // Version already offered to the user

    public static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            appearance: AppThemePreference.auto.rawValue,
            editorFontSize: 13.0,
            showLineNumbers: true,
            wrapLines: true,
            texEngine: "auto",
            texPath: "",
            compileOnSave: true,
            darkPDF: false,
            pdfZoomMode: "fitWidth",
            restoreSession: true,
            autoCheckUpdates: true,
        ])
    }
}
