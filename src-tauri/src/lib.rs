mod tex;

use serde::Serialize;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{Emitter, Manager, RunEvent};

type Res<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

#[tauri::command]
fn read_text(path: String) -> Res<String> {
    fs::read_to_string(path).map_err(err)
}

/// Atomic save: write a sibling temp file, fsync, rename over the target.
/// A crash mid-save leaves either the old file or the new one, never half of one.
pub fn atomic_write(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let name = path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default();
    // create_new never follows a planted symlink; the nanos suffix avoids a stale leftover.
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    let tmp = path.with_file_name(format!(".{name}.{nanos}.cpsave"));
    let mut f = fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
    let done = (|| {
        if let Ok(m) = fs::metadata(path) {
            f.set_permissions(m.permissions())?;
        }
        f.write_all(data)?;
        f.sync_all()?;
        fs::rename(&tmp, path)
    })();
    if done.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    done
}

#[tauri::command]
fn write_text(path: String, contents: String) -> Res<()> {
    atomic_write(Path::new(&path), contents.as_bytes()).map_err(err)
}

// ponytail: bytes arrive as a JSON array; fine for occasional PNG export, switch to a raw ipc body if exports get big.
#[tauri::command]
fn write_bytes(path: String, data: Vec<u8>) -> Res<()> {
    atomic_write(Path::new(&path), &data).map_err(err)
}

#[tauri::command]
fn read_bytes(path: String) -> Res<tauri::ipc::Response> {
    fs::read(path).map(tauri::ipc::Response::new).map_err(err)
}

#[tauri::command]
fn copy_file(from: String, to: String) -> Res<()> {
    fs::copy(from, to).map(|_| ()).map_err(err)
}

/// New project folder; fails if it already exists so an existing folder is never reused by accident.
#[tauri::command]
fn create_dir(path: String) -> Res<()> {
    fs::create_dir(path).map_err(err)
}

#[tauri::command]
fn exists(path: String) -> bool {
    Path::new(&path).exists()
}

#[derive(Serialize)]
struct Entry {
    name: String,
    path: String,
    dir: bool,
    children: Vec<Entry>,
}

const SKIP: &[&str] = &["node_modules", "target", "dist"];

/// Folder tree limited to files with one of `exts`; folders with no matching files are dropped.
fn tree(dir: &Path, exts: &[String], depth: u8) -> Vec<Entry> {
    let Ok(rd) = fs::read_dir(dir) else { return vec![] };
    let mut out: Vec<Entry> = rd
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || SKIP.contains(&name.as_str()) {
                return None;
            }
            let path = e.path();
            if path.is_dir() {
                // ponytail: depth cap stops a stray open of ~ from walking the whole disk.
                let children = if depth < 6 { tree(&path, exts, depth + 1) } else { vec![] };
                (!children.is_empty()).then(|| Entry { name, path: path.to_string_lossy().into(), dir: true, children })
            } else {
                let ext = path.extension()?.to_string_lossy().to_lowercase();
                exts.contains(&ext).then(|| Entry { name, path: path.to_string_lossy().into(), dir: false, children: vec![] })
            }
        })
        .collect();
    out.sort_by(|a, b| b.dir.cmp(&a.dir).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    out
}

#[tauri::command]
fn list_tree(root: String, exts: Vec<String>) -> Vec<Entry> {
    tree(Path::new(&root), &exts, 0)
}

/// Paths macOS asked us to open (Finder double-click, Dock drop) before the UI was listening.
#[derive(Default)]
struct Opened(Mutex<Vec<String>>);

#[tauri::command]
fn take_opened(state: tauri::State<Opened>) -> Vec<String> {
    std::mem::take(&mut *state.0.lock().unwrap())
}

#[tauri::command]
fn quit(app: tauri::AppHandle) {
    app.exit(0);
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Opened::default())
        .manage(tex::Running::default())
        .invoke_handler(tauri::generate_handler![
            read_text,
            write_text,
            write_bytes,
            read_bytes,
            copy_file,
            exists,
            create_dir,
            list_tree,
            take_opened,
            tex::tex_root,
            tex::compile,
            tex::cancel_compile,
            tex::clean_build,
            tex::synctex_view,
            tex::synctex_edit,
            tex::tex_status,
            quit,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, ev| {
            // Cmd+Q: let the frontend flush pending saves, then it calls `quit`.
            if let RunEvent::ExitRequested { code: None, api, .. } = &ev
                && app.emit("flush", ()).is_ok()
            {
                api.prevent_exit();
            }
            #[cfg(target_os = "macos")]
            if let RunEvent::Opened { urls } = ev {
                let paths: Vec<String> = urls
                    .iter()
                    .filter_map(|u| u.to_file_path().ok())
                    .map(|p: PathBuf| p.to_string_lossy().into_owned())
                    .collect();
                app.state::<Opened>().0.lock().unwrap().extend(paths.clone());
                let _ = app.emit("open-paths", paths);
            }
            #[cfg(not(target_os = "macos"))]
            let _ = (app, ev);
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atomic_write_replaces_and_leaves_no_temp() {
        let dir = std::env::temp_dir().join(format!("cp-aw-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let f = dir.join("a.md");
        atomic_write(&f, b"one").unwrap();
        atomic_write(&f, b"two").unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap(), "two");
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn tree_filters_and_drops_empty_dirs() {
        let dir = std::env::temp_dir().join(format!("cp-tree-{}", std::process::id()));
        fs::create_dir_all(dir.join("ch")).unwrap();
        fs::create_dir_all(dir.join("empty")).unwrap();
        fs::create_dir_all(dir.join(".build")).unwrap();
        for f in ["main.tex", "notes.md", "ch/one.tex", ".build/main.tex"] {
            fs::write(dir.join(f), "").unwrap();
        }
        let t = tree(&dir, &["tex".into()], 0);
        let names: Vec<_> = t.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, ["ch", "main.tex"]);
        assert_eq!(t[0].children[0].name, "one.tex");
        fs::remove_dir_all(dir).unwrap();
    }
}
