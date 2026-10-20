import Foundation

/// Maps common TeX errors and warnings to short, beginner-friendly explanations with a fix hint.
public enum DiagnosticExplainer {
    // Order matters: more specific patterns come before generic ones.
    private static let rules: [(matches: (String) -> Bool, explain: (String) -> String)] = [
        ({ $0.contains("undefined control sequence") },
         { _ in "LaTeX doesn't know this command. Check its spelling, or load the package that defines it with \\usepackage{...}." }),
        ({ $0.contains("missing $ inserted") },
         { _ in "A math-only symbol (like ^, _ or \\alpha) is used outside math mode. Wrap it in $...$, or escape it (e.g. \\_ for an underscore)." }),
        ({ $0.contains("i can't find file") },
         { m in "LaTeX can't find \(quoted(m) ?? "the file you included"). Check the file name and path in \\input or \\include (paths are relative to the main file)." }),
        ({ $0.contains("file `") && $0.contains("not found") },
         { m in "\(quoted(m) ?? "A required file") is not installed or can't be found. Check the spelling, or install the package with TeX Live Utility or `tlmgr install <package>`." }),
        ({ $0.contains("runaway argument") },
         { _ in "A command's argument never ends, usually because a closing brace } is missing. Look just before the reported line." }),
        ({ $0.contains("missing \\begin{document}") },
         { _ in "Text appears before \\begin{document}. Move it into the document body, or remove stray characters from the preamble." }),
        ({ $0.contains("ended by \\end{") },
         { _ in "Environments are mismatched: a \\begin{...} is closed by a different \\end{...}. Make sure every \\begin has a matching \\end, in the right order." }),
        ({ $0.contains("environment") && $0.contains("undefined") },
         { _ in "This environment isn't defined. Check its spelling, or load the package that provides it (e.g. amsmath for align)." }),
        ({ $0.contains("extra }, or forgotten $") },
         { _ in "There's a } without a matching {, or a math formula opened with $ was never closed." }),
        ({ $0.contains("too many }'s") },
         { _ in "There's a closing brace } with no matching opening brace {. Remove it or add the missing {." }),
        ({ $0.contains("there were undefined references") },
         { _ in "Some \\ref or \\cite targets were missing. Compile again; if this stays, check your \\label names and citation keys." }),
        ({ $0.contains("citation") && $0.contains("undefined") },
         { _ in "This \\cite key isn't in your bibliography. Check the key in your .bib file, then compile again so BibTeX/Biber can pick it up." }),
        ({ $0.contains("reference") && $0.contains("undefined") },
         { _ in "This \\ref points to a label that doesn't exist (yet). Check the \\label name; if you just added it, compile again." }),
        ({ $0.contains("multiply defined") },
         { _ in "The same \\label name is used more than once. Give each label a unique name." }),
        ({ $0.contains("overfull \\hbox") },
         { _ in "A line is too wide and sticks into the margin. Rephrase the sentence, or break long words, URLs or formulas." }),
        ({ $0.contains("underfull \\hbox") },
         { _ in "A line is spaced too loosely, often caused by \\\\ or \\newline. Usually harmless; removing manual line breaks fixes it." }),
        ({ $0.contains("emergency stop") },
         { _ in "LaTeX had to stop early because of an earlier problem. Fix the first error in the list; this one usually disappears." }),
        ({ $0.contains("package inputenc error") },
         { _ in "The file contains a character the input encoding can't handle. Save the file as UTF-8, or compile with XeLaTeX or LuaLaTeX for full Unicode." }),
        ({ ($0.contains("font") && ($0.contains("cannot be found") || $0.contains("not found") || $0.contains("not loadable"))) },
         { _ in "This font isn't installed on your Mac. Install it, or use the exact font name shown in Font Book (needs XeLaTeX or LuaLaTeX)." })
    ]

    public static func explain(_ message: String) -> String? {
        let lower = message.lowercased()
        return rules.first { $0.matches(lower) }?.explain(message)
    }

    /// Extracts the TeX-quoted name in `` `name' ``, if any.
    private static func quoted(_ message: String) -> String? {
        guard let open = message.firstIndex(of: "`"),
              let close = message[message.index(after: open)...].firstIndex(of: "'") else { return nil }
        let name = message[message.index(after: open)..<close]
        return name.isEmpty ? nil : String(name)
    }
}
