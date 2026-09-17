#![allow(dead_code)]

use cargo_metadata::{Metadata, MetadataCommand};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn lane_root() -> PathBuf {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("hygiene crate must stay inside the extension lane")
        .to_path_buf();
    assert!(root.join("Justfile").is_file(), "{} is not the lane root", root.display());
    root
}

pub fn repository_root() -> PathBuf {
    let root = lane_root()
        .parent()
        .and_then(Path::parent)
        .expect("extensions/money-pg must stay below the repository root")
        .to_path_buf();
    assert!(
        root.join("Cargo.toml").is_file() && root.join("crates").is_dir(),
        "{} is not the repository root",
        root.display()
    );
    root
}

pub fn read(path: impl AsRef<Path>) -> String {
    let path = path.as_ref();
    std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("{} must be readable: {error}", path.display()))
}

pub fn rust_sources_under(root: &Path) -> Vec<PathBuf> {
    fn collect(directory: &Path, files: &mut Vec<PathBuf>) {
        for entry in std::fs::read_dir(directory)
            .unwrap_or_else(|error| panic!("{} must be readable: {error}", directory.display()))
        {
            let path = entry.expect("directory entry must be readable").path();
            if path.is_dir() {
                collect(&path, files);
            } else if path.extension().is_some_and(|extension| extension == "rs") {
                files.push(path);
            }
        }
    }

    let mut files = Vec::new();
    collect(root, &mut files);
    files.sort();
    files
}

pub fn tracked_files(pathspec: Option<&str>) -> Vec<PathBuf> {
    let mut command = Command::new("git");
    command.args(["ls-files", "--cached", "--others", "--exclude-standard", "-z"]);
    if let Some(pathspec) = pathspec {
        command.arg(pathspec);
    }
    let output = command.current_dir(lane_root()).output().expect("git ls-files must run");
    assert!(output.status.success(), "git ls-files failed");
    output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .map(|path| PathBuf::from(String::from_utf8_lossy(path).into_owned()))
        .collect()
}

pub fn metadata() -> Metadata {
    MetadataCommand::new()
        .manifest_path(lane_root().join("Cargo.toml"))
        .no_deps()
        .exec()
        .expect("lane cargo metadata must resolve")
}

pub fn manifest(path: impl AsRef<Path>) -> toml::Value {
    let path = path.as_ref();
    toml::from_str(&read(path))
        .unwrap_or_else(|error| panic!("{} must parse as TOML: {error}", path.display()))
}

pub fn just_dump(root: &Path) -> Value {
    let output = Command::new("just")
        .args(["--dump", "--dump-format", "json"])
        .current_dir(root)
        .output()
        .expect("just --dump must run");
    assert!(output.status.success(), "just --dump failed: {}", String::from_utf8_lossy(&output.stderr));
    serde_json::from_slice(&output.stdout).expect("just --dump must return JSON")
}

pub fn recipe<'a>(dump: &'a Value, name: &str) -> &'a Value {
    dump.get("recipes")
        .and_then(|recipes| recipes.get(name))
        .unwrap_or_else(|| panic!("Justfile must define `{name}`"))
}

pub fn recipe_dependencies<'a>(dump: &'a Value, name: &str) -> Vec<&'a str> {
    recipe(dump, name)
        .get("dependencies")
        .and_then(Value::as_array)
        .expect("recipe dependencies must be an array")
        .iter()
        .filter_map(|dependency| dependency.get("recipe").and_then(Value::as_str))
        .collect()
}

pub fn recipe_body(dump: &Value, name: &str) -> String {
    fn render(fragment: &Value, output: &mut String) {
        match fragment {
            Value::String(text) => output.push_str(text),
            Value::Array(parts)
                if parts.len() == 2 && parts.first().and_then(Value::as_str) == Some("variable") =>
            {
                output.push_str("{{ ");
                output.push_str(parts[1].as_str().expect("variable fragment must name a parameter"));
                output.push_str(" }}");
            }
            Value::Array(parts) => {
                for part in parts {
                    render(part, output);
                }
            }
            _ => {}
        }
    }

    recipe(dump, name)
        .get("body")
        .and_then(Value::as_array)
        .expect("recipe body must be an array")
        .iter()
        .filter_map(|line| {
            let mut rendered = String::new();
            render(line, &mut rendered);
            (!rendered.trim_start().starts_with('#')).then_some(rendered)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Join backslash continuations, so a guard reads whole COMMANDS rather than the lines a command
/// happens to be spread over.
///
/// Every caller is looking for two things that must appear together -- a build and its context, a
/// compile and the argument that scopes it. Reading raw lines would let a command satisfy such a
/// guard by being wrapped, or evade it the same way. Each entry carries the 1-based line the
/// command started on, so a diagnostic can name it.
pub fn logical_lines(source: &str) -> Vec<(usize, String)> {
    let mut lines = Vec::new();
    let mut logical = String::new();
    let mut start = 0;
    for (index, line) in source.lines().enumerate() {
        if logical.is_empty() {
            start = index + 1;
        }
        // A comment ends at its newline: neither bash nor just continues one through a trailing
        // backslash. Joining it to the command beneath would hide that command from every caller
        // that skips comments -- so a `docker build` written under a wrapped comment would never
        // be examined for the arguments it must carry.
        let comment = logical.is_empty() && line.trim_start().starts_with('#');
        logical.push_str(if comment { line } else { line.strip_suffix('\\').unwrap_or(line) });
        if comment || !line.ends_with('\\') {
            lines.push((start, std::mem::take(&mut logical)));
        }
    }
    if !logical.is_empty() {
        lines.push((start, logical));
    }
    lines
}

pub fn recipe_empty_parameters(dump: &Value, name: &str) -> Vec<String> {
    recipe(dump, name)
        .get("parameters")
        .and_then(Value::as_array)
        .expect("recipe parameters must be an array")
        .iter()
        .filter(|parameter| parameter.get("default").and_then(Value::as_str) == Some(""))
        .filter_map(|parameter| parameter.get("name").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

/// What one shell invocation produced.
///
/// The three fields are kept apart because which stream a message lands on is part of several
/// contracts under test: `yb-image.sh` and `exactly-one.sh` are read for their stdout by callers
/// that discard the status, so a refusal that still printed a path would be acted on.
pub struct Shell {
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

impl Shell {
    pub fn succeeded(&self) -> bool {
        self.status == 0
    }

    /// The two streams together, for a caller that only wants "was this reason reported".
    pub fn output(&self) -> String {
        format!("{}{}", self.stdout, self.stderr)
    }
}

/// Run `program` from `directory`, with `environment` applied on top of the inherited one.
///
/// A `None` value REMOVES a variable rather than emptying it. Several controls need that: an
/// inherited `KMONEY_WORKSPACE_LOCK_FD` or `BENCH_NUMA_NODE` would arm the case instead of
/// testing it, and both scripts distinguish unset from empty.
pub fn run(
    program: impl AsRef<std::ffi::OsStr>,
    arguments: &[&str],
    directory: &Path,
    environment: &[(&str, Option<&str>)],
) -> Shell {
    let mut command = Command::new(program);
    command.args(arguments).current_dir(directory);
    for (name, value) in environment {
        match value {
            Some(value) => command.env(name, value),
            None => command.env_remove(name),
        };
    }
    let output = command.output().expect("the program must run");
    Shell {
        // A signalled process has no code. -1 is not a status any of these scripts returns, so it
        // reads as "killed" rather than colliding with a refusal.
        status: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

/// Run `script` under `bash -c`, which is how a caller that sources one of these libraries
/// reaches the functions inside it.
pub fn bash(directory: &Path, script: &str, environment: &[(&str, Option<&str>)]) -> Shell {
    run("bash", &["-c", script], directory, environment)
}

/// A scratch tree that removes itself.
///
/// Integration tests in one binary run as threads of one process, so the label alone is not
/// unique; the counter makes it so without a clock or a random source.
pub struct Scratch {
    path: PathBuf,
}

impl Scratch {
    pub fn new(label: &str) -> Self {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let serial = NEXT.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("kmoney-selftest-{label}-{}-{serial}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("scratch tree must be creatable");
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn join(&self, relative: impl AsRef<Path>) -> PathBuf {
        self.path.join(relative)
    }

    /// Create a directory and every parent, returning it.
    pub fn directory(&self, relative: impl AsRef<Path>) -> PathBuf {
        let path = self.join(relative);
        std::fs::create_dir_all(&path).expect("scratch directory must be creatable");
        path
    }

    /// Write a file, creating its parent directories.
    pub fn write(&self, relative: impl AsRef<Path>, contents: &str) -> PathBuf {
        let path = self.join(relative);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("scratch parent must be creatable");
        }
        std::fs::write(&path, contents)
            .unwrap_or_else(|error| panic!("{} must be writable: {error}", path.display()));
        path
    }

    /// Write a file and make it executable, for the stub programs several controls put on `PATH`.
    pub fn write_program(&self, relative: impl AsRef<Path>, contents: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = self.write(relative, contents);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))
            .expect("scratch program must be executable");
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
