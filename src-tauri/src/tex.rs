//! LaTeX backend: find TeX Live, pick root + engine, run latexmk, parse the log, SyncTeX via CLI.

use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::Instant;

type Res<T> = Result<T, String>;

pub const OUTDIR: &str = ".build";

/// Finder-launched apps get a bare PATH, so look in the TeX Live locations directly.
pub fn texbin() -> Option<PathBuf> {
    let fixed = PathBuf::from("/Library/TeX/texbin");
    if fixed.join("latexmk").exists() {
        return Some(fixed);
    }
    let mut years: Vec<_> = fs::read_dir("/usr/local/texlive").ok()?.flatten().map(|e| e.path()).collect();
    years.sort();
    years.into_iter().rev().find_map(|y| {
        fs::read_dir(y.join("bin")).ok()?.flatten().map(|e| e.path()).find(|b| b.join("latexmk").exists())
    })
}

fn tool(name: &str) -> Res<Command> {
    let bin = texbin().ok_or("TeX Live not found (looked in /Library/TeX/texbin and /usr/local/texlive)")?;
    let mut c = Command::new(bin.join(name));
    // latexmk spawns pdflatex/bibtex/biber by name, so they must be on PATH.
    c.env("PATH", format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", bin.display()));
    Ok(c)
}

/// `% !TEX program = xelatex` in the first lines picks the engine; default pdflatex.
pub fn detect_engine(src: &str) -> &'static str {
    for line in src.lines().take(20) {
        let l = line.trim().to_lowercase();
        if let Some(rest) = l.strip_prefix('%') {
            let rest = rest.trim().replace(' ', "");
            if let Some(p) = rest.strip_prefix("!texprogram=").or_else(|| rest.strip_prefix("!tex:program=")) {
                return match p {
                    "xelatex" => "xelatex",
                    "lualatex" => "lualatex",
                    _ => "pdflatex",
                };
            }
        }
    }
    "pdflatex"
}

fn has_documentclass(src: &str) -> bool {
    src.lines().any(|l| {
        let code = l.split('%').next().unwrap_or("");
        code.contains("\\documentclass")
    })
}

fn magic_root(src: &str) -> Option<String> {
    src.lines().take(20).find_map(|l| {
        let t = l.trim();
        let rest = t.strip_prefix('%')?.trim();
        let (k, v) = rest.split_once('=')?;
        let k = k.trim().to_lowercase().replace(' ', "");
        (k == "!texroot").then(|| v.trim().to_string())
    })
}

/// Root document for `file`: itself if it has \documentclass, else a `% !TEX root`, else a sibling
/// .tex with \documentclass (main.tex first). None means "snippet": render as math, don't compile.
pub fn detect_root(file: &Path) -> Option<PathBuf> {
    let src = fs::read_to_string(file).ok()?;
    if has_documentclass(&src) {
        return Some(file.to_path_buf());
    }
    let dir = file.parent()?;
    if let Some(r) = magic_root(&src) {
        let p = dir.join(r);
        return p.exists().then_some(p);
    }
    let mut cands: Vec<PathBuf> = fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "tex") && p != file)
        .collect();
    cands.sort_by_key(|p| p.file_name().is_none_or(|n| n != "main.tex"));
    cands.into_iter().find(|p| fs::read_to_string(p).is_ok_and(|s| has_documentclass(&s)))
}

pub fn pdf_path(root: &Path) -> PathBuf {
    root.parent().unwrap().join(OUTDIR).join(root.with_extension("pdf").file_name().unwrap())
}

#[derive(Serialize, Debug, PartialEq)]
pub struct Diag {
    pub file: String,
    pub line: u32,
    pub message: String,
    pub warning: bool,
}

/// TeX repeats messages on each latexmk pass; keep the first.
fn push_unique(out: &mut Vec<Diag>, d: Diag) {
    if !out.contains(&d) {
        out.push(d);
    }
}

/// Errors come from `-file-line-error` lines (`./ch.tex:12: Undefined control sequence.`);
/// warnings from `... on input line N.` (attributed to the root, TeX doesn't say which file).
pub fn parse_log(log: &str, root: &Path) -> Vec<Diag> {
    let dir = root.parent().unwrap_or(Path::new("."));
    let mut out = vec![];
    for l in log.lines() {
        if let Some((file, rest)) = l.split_once(".tex:")
            && let Some((num, msg)) = rest.split_once(": ")
            && let Ok(line) = num.parse()
        {
            let p = dir.join(format!("{}.tex", file.trim()));
            let file = p.canonicalize().unwrap_or(p).to_string_lossy().into_owned();
            push_unique(&mut out, Diag { file, line, message: msg.trim().into(), warning: false });
        } else if l.contains("Warning:")
            && let Some(i) = l.rfind("input line ")
            && let Ok(line) = l[i + 11..].chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse()
        {
            let msg = l.split_once("Warning:").map(|x| x.1).unwrap_or(l).trim();
            push_unique(&mut out, Diag { file: root.to_string_lossy().into(), line, message: msg.into(), warning: true });
        }
    }
    out
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RootInfo {
    root: Option<String>,
    engine: &'static str,
}

#[tauri::command]
pub fn tex_root(file: String) -> RootInfo {
    let root = detect_root(Path::new(&file));
    let engine = root
        .as_ref()
        .and_then(|r| fs::read_to_string(r).ok())
        .map(|s| detect_engine(&s))
        .unwrap_or("pdflatex");
    RootInfo { root: root.map(|r| r.to_string_lossy().into_owned()), engine }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TexStatus {
    found: bool,
    path: Option<String>,
}

#[tauri::command]
pub fn tex_status() -> TexStatus {
    let p = texbin();
    TexStatus { found: p.is_some(), path: p.map(|p| p.to_string_lossy().into_owned()) }
}

/// Process-group id of the running latexmk, so cancel can kill it and the engine it spawned.
#[derive(Default)]
pub struct Running(Mutex<Option<u32>>);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompileResult {
    ok: bool,
    cancelled: bool,
    /// Present when a PDF was produced by this run (TeX often still produces one despite errors).
    pdf: Option<String>,
    diagnostics: Vec<Diag>,
    log: String,
    ms: u128,
    engine: &'static str,
}

pub fn run_latexmk(root: &Path, running: Option<&Running>) -> Res<CompileResult> {
    use std::os::unix::process::CommandExt;
    let start = Instant::now();
    let src = fs::read_to_string(root).map_err(|e| e.to_string())?;
    let engine = detect_engine(&src);
    let dir = root.parent().ok_or("bad path")?;
    let name = root.file_name().ok_or("bad path")?;
    let pdf = pdf_path(root);
    let before = fs::metadata(&pdf).and_then(|m| m.modified()).ok();

    let mut cmd = tool("latexmk")?;
    let flag = match engine {
        "xelatex" => "-xelatex",
        "lualatex" => "-lualatex",
        _ => "-pdf",
    };
    cmd.current_dir(dir)
        // -norc: a project latexmkrc is Perl and would run on Compile. ponytail: also skips ~/.latexmkrc.
        .args(["-norc", flag, "-interaction=nonstopmode", "-file-line-error", "-synctex=1"])
        .arg(format!("-outdir={OUTDIR}"))
        .arg(name)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .process_group(0);
    let child = cmd.spawn().map_err(|e| e.to_string())?;
    if let Some(r) = running {
        *r.0.lock().unwrap() = Some(child.id());
    }
    let out = child.wait_with_output().map_err(|e| e.to_string());
    let cancelled = running.is_some_and(|r| r.0.lock().unwrap().take().is_none());
    let out = out?;

    let log_file = pdf.with_extension("log");
    let log = fs::read_to_string(&log_file)
        .unwrap_or_else(|_| String::from_utf8_lossy(&out.stdout).into_owned() + &String::from_utf8_lossy(&out.stderr));
    let fresh = fs::metadata(&pdf).and_then(|m| m.modified()).ok().filter(|m| Some(*m) != before);
    // latexmk with nothing to rebuild leaves the PDF untouched but succeeds: still show it.
    let pdf_out = (fresh.is_some() || (out.status.success() && pdf.exists())).then(|| pdf.to_string_lossy().into_owned());
    Ok(CompileResult {
        ok: out.status.success(),
        cancelled,
        pdf: pdf_out,
        diagnostics: parse_log(&log, root),
        log,
        ms: start.elapsed().as_millis(),
        engine,
    })
}

#[tauri::command]
pub async fn compile(root: String, app: tauri::AppHandle) -> Res<CompileResult> {
    use tauri::Manager;
    tauri::async_runtime::spawn_blocking(move || run_latexmk(Path::new(&root), Some(&app.state::<Running>())))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn cancel_compile(state: tauri::State<Running>) {
    if let Some(pgid) = state.0.lock().unwrap().take() {
        let _ = Command::new("/bin/kill").args(["-TERM", "--", &format!("-{pgid}")]).status();
    }
}

#[tauri::command]
pub async fn clean_build(root: String) -> Res<()> {
    tauri::async_runtime::spawn_blocking(move || {
        let dir = Path::new(&root).parent().ok_or("bad path")?.join(OUTDIR);
        if dir.exists() {
            fs::remove_dir_all(dir).map_err(|e| e.to_string())?;
        }
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?
}

fn field<'a>(block: &'a str, key: &str) -> Option<&'a str> {
    block.lines().find_map(|l| l.strip_prefix(key)).map(str::trim)
}

#[derive(Serialize, Debug)]
pub struct Spot {
    page: u32,
    /// Box in PDF points, origin top-left, y down (matches pdf.js CSS px / scale).
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

/// Source -> PDF. Returns every box for the line (one line can span a page break).
pub fn synctex_view_impl(file: &Path, line: u32, col: u32, pdf: &Path) -> Res<Vec<Spot>> {
    let out = tool("synctex")?
        .arg("view")
        .arg("-i")
        .arg(format!("{line}:{col}:{}", file.display()))
        .arg("-o")
        .arg(pdf)
        .output()
        .map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout);
    let spots = text
        .split("Output:")
        .skip(1)
        .filter_map(|b| {
            let n = |k| field(b, k).and_then(|v| v.parse::<f64>().ok());
            let (h, v, w, hh) = (n("h:")?, n("v:")?, n("W:")?, n("H:")?);
            Some(Spot { page: field(b, "Page:")?.parse().ok()?, x: h, y: v - hh, w, h: hh })
        })
        .collect();
    Ok(spots)
}

#[tauri::command]
pub async fn synctex_view(file: String, line: u32, col: u32, pdf: String) -> Res<Vec<Spot>> {
    tauri::async_runtime::spawn_blocking(move || synctex_view_impl(Path::new(&file), line, col, Path::new(&pdf)))
        .await
        .map_err(|e| e.to_string())?
}

#[derive(Serialize, Debug)]
pub struct SourceLoc {
    file: String,
    line: u32,
}

/// PDF -> source. `x`, `y` in PDF points from the page's top-left.
pub fn synctex_edit_impl(pdf: &Path, page: u32, x: f64, y: f64) -> Res<Option<SourceLoc>> {
    let out = tool("synctex")?
        .arg("edit")
        .arg("-o")
        .arg(format!("{page}:{x:.2}:{y:.2}:{}", pdf.display()))
        .output()
        .map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout);
    let Some(input) = field(&text, "Input:") else { return Ok(None) };
    let line: u32 = field(&text, "Line:").and_then(|l| l.parse().ok()).unwrap_or(1).max(1);
    // Input may be relative to the project dir (latexmk runs there) and contain "./".
    let project = pdf.parent().and_then(Path::parent).unwrap_or(Path::new("/"));
    let p = project.join(input);
    let file = p.canonicalize().unwrap_or(p).to_string_lossy().into_owned();
    Ok(Some(SourceLoc { file, line }))
}

#[tauri::command]
pub async fn synctex_edit(pdf: String, page: u32, x: f64, y: f64) -> Res<Option<SourceLoc>> {
    tauri::async_runtime::spawn_blocking(move || synctex_edit_impl(Path::new(&pdf), page, x, y))
        .await
        .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("cp-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn engine_magic_comment() {
        assert_eq!(detect_engine("% !TEX program = xelatex\n\\documentclass{article}"), "xelatex");
        assert_eq!(detect_engine("%!TEX TS-program = lualatex"), "pdflatex"); // unknown key: default
        assert_eq!(detect_engine("% !TEX program=LuaLaTeX"), "lualatex");
        assert_eq!(detect_engine("\\documentclass{article}"), "pdflatex");
    }

    #[test]
    fn root_detection() {
        let d = tmp("root");
        fs::write(d.join("main.tex"), "\\documentclass{article}\n\\begin{document}\\input{ch}\\end{document}").unwrap();
        fs::write(d.join("ch.tex"), "\\section{A}").unwrap();
        fs::write(d.join("magic.tex"), "% !TEX root = main.tex\n").unwrap();
        fs::write(d.join("commented.tex"), "% \\documentclass{article}\n$x$").unwrap();
        assert_eq!(detect_root(&d.join("main.tex")).unwrap(), d.join("main.tex"));
        assert_eq!(detect_root(&d.join("ch.tex")).unwrap(), d.join("main.tex"));
        assert_eq!(detect_root(&d.join("magic.tex")).unwrap(), d.join("main.tex"));
        let lone = tmp("snippet");
        fs::write(lone.join("snip.tex"), "\\int_0^1 x\\,dx").unwrap();
        assert!(detect_root(&lone.join("snip.tex")).is_none());
    }

    #[test]
    fn log_parsing() {
        let root = Path::new("/p/main.tex");
        let log = "./ch.tex:12: Undefined control sequence.\n\
                   LaTeX Warning: Reference `fig' on page 1 undefined on input line 7.\n\
                   ./ch.tex:12: Undefined control sequence.\n\
                   Overfull \\hbox in paragraph";
        let d = parse_log(log, root);
        assert_eq!(d.len(), 2);
        assert_eq!((d[0].line, d[0].warning), (12, false));
        assert!(d[0].file.ends_with("ch.tex"));
        assert_eq!((d[1].line, d[1].warning), (7, true));
    }

    /// Real compile + SyncTeX round trip against the installed TeX Live. Skips if TeX is absent.
    #[test]
    fn compile_and_synctex_round_trip() {
        if texbin().is_none() {
            eprintln!("skipping: no TeX Live");
            return;
        }
        let d = tmp("compile");
        let root = d.join("main.tex");
        fs::write(&root, "\\documentclass{article}\n\\begin{document}\nHello\n\nSecond paragraph here.\n\\end{document}\n").unwrap();
        let r = run_latexmk(&root, None).unwrap();
        assert!(r.ok, "{}", r.log);
        let pdf = PathBuf::from(r.pdf.unwrap());
        assert!(pdf.exists());

        let spots = synctex_view_impl(&root, 5, 1, &pdf).unwrap();
        assert!(!spots.is_empty());
        assert_eq!(spots[0].page, 1);
        let s = &spots[0];
        let loc = synctex_edit_impl(&pdf, 1, s.x + 2.0, s.y + s.h / 2.0).unwrap().unwrap();
        assert!(loc.file.ends_with("main.tex"), "{}", loc.file);
        assert_eq!(loc.line, 5);

        fs::write(&root, "\\documentclass{article}\n\\begin{document}\n\\oops\n\\end{document}\n").unwrap();
        let bad = run_latexmk(&root, None).unwrap();
        assert!(!bad.ok);
        assert!(bad.diagnostics.iter().any(|x| x.line == 3 && !x.warning), "{:?}", bad.diagnostics);
    }
}
