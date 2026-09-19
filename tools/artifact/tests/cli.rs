#![forbid(unsafe_code)]
#![deny(warnings, clippy::all)]

use sha2::{Digest, Sha256};
use std::fmt::Write as _;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

const BINARY: &str = env!("CARGO_BIN_EXE_kamu-money-pg-artifact");

struct Fixture {
    root: tempfile::TempDir,
}

impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("kmoney.so"), b"owned-library\n").unwrap();
        fs::write(root.path().join("kmoney.control"), b"default_version = '0.1.0'\n").unwrap();
        fs::write(root.path().join("kmoney--0.1.0.sql"), b"SELECT 1;\n").unwrap();
        let manifest = ["kmoney.so", "kmoney.control", "kmoney--0.1.0.sql"]
            .iter()
            .map(|name| {
                let digest = hex(&Sha256::digest(fs::read(root.path().join(name)).unwrap()));
                format!("{digest}  {name}\n")
            })
            .collect::<String>();
        fs::write(root.path().join("ARTIFACT-MANIFEST.txt"), manifest).unwrap();
        Self { root }
    }

    fn path(&self) -> &Path {
        self.root.path()
    }
}

fn stub(directory: &Path, name: &str, body: &str) {
    let path = directory.join(name);
    fs::write(&path, format!("#!/bin/sh\nset -eu\n{body}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn run(arguments: &[&str], bin: &Path, extra: &[(&str, &Path)]) -> Output {
    let old_path = std::env::var_os("PATH").unwrap_or_default();
    let mut paths = vec![bin.to_path_buf()];
    paths.extend(std::env::split_paths(&old_path));
    let mut command = Command::new(BINARY);
    command.args(arguments).env("PATH", std::env::join_paths(paths).unwrap());
    for (name, value) in extra {
        command.env(name, value);
    }
    command.output().unwrap()
}

fn run_with_umask(arguments: &[&str], bin: &Path, extra: &[(&str, &Path)]) -> Output {
    let old_path = std::env::var_os("PATH").unwrap_or_default();
    let mut paths = vec![bin.to_path_buf()];
    paths.extend(std::env::split_paths(&old_path));
    let mut command = Command::new("sh");
    command
        .args(["-c", "umask 077; exec \"$@\"", "sh", BINARY])
        .args(arguments)
        .env("PATH", std::env::join_paths(paths).unwrap());
    for (name, value) in extra {
        command.env(name, value);
    }
    command.output().unwrap()
}

#[test]
fn copy_receipt_follows_three_copies_of_verified_owned_bytes() {
    let fixture = Fixture::new();
    let tools = tempfile::tempdir().unwrap();
    let copied = tempfile::tempdir().unwrap();
    stub(
        tools.path(),
        "docker",
        r#"test "$1" = cp
count_file="$FAKE_OUT/count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "$count" = 1 ]; then
    printf 'mutated-library\n' > "$FIXTURE/kmoney.so"
    printf "default_version = '9.9.9'\n" > "$FIXTURE/kmoney.control"
    printf 'mutated SQL\n' > "$FIXTURE/kmoney--0.1.0.sql"
fi
stat -c '%a' "$2" >> "$FAKE_OUT/modes"
cp "$2" "$FAKE_OUT/$(basename "$2")""#,
    );

    let output = run_with_umask(
        &["copy-to-node", fixture.path().to_str().unwrap(), "node-1"],
        tools.path(),
        &[("FAKE_OUT", copied.path()), ("FIXTURE", fixture.path())],
    );
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let fields = String::from_utf8(output.stdout).unwrap();
    let fields = fields.trim_end().split('\t').collect::<Vec<_>>();
    assert_eq!(fields.len(), 4);
    assert_eq!(&fields[..3], ["copied", "verified", "0.1.0"]);
    assert_eq!(fields[3], hex(&Sha256::digest(b"owned-library\n")));
    assert_eq!(fs::read(copied.path().join("kmoney.so")).unwrap(), b"owned-library\n");
    assert_eq!(fs::read(copied.path().join("kmoney.control")).unwrap(), b"default_version = '0.1.0'\n");
    assert_eq!(fs::read(copied.path().join("kmoney--0.1.0.sql")).unwrap(), b"SELECT 1;\n");
    assert_eq!(fs::read_to_string(copied.path().join("modes")).unwrap(), "755\n644\n644\n");
}

#[test]
fn developer_copy_prefers_valid_manifest_and_falls_back_only_when_absent() {
    let fixture = Fixture::new();
    let tools = tempfile::tempdir().unwrap();
    let copied = tempfile::tempdir().unwrap();
    stub(tools.path(), "docker", "test \"$1\" = cp\ncp \"$2\" \"$FAKE_OUT/$(basename \"$2\")\"");

    let output = run(
        &["copy-to-node-dev", fixture.path().to_str().unwrap(), "node-1"],
        tools.path(),
        &[("FAKE_OUT", copied.path())],
    );
    assert!(output.status.success());
    assert!(String::from_utf8(output.stdout).unwrap().starts_with("copied\tverified\t"));

    fs::remove_file(fixture.path().join("ARTIFACT-MANIFEST.txt")).unwrap();
    let output = run(
        &["copy-to-node-dev", fixture.path().to_str().unwrap(), "node-1"],
        tools.path(),
        &[("FAKE_OUT", copied.path())],
    );
    assert!(output.status.success());
    assert!(String::from_utf8(output.stdout).unwrap().starts_with("copied\tunverified\t"));
    assert!(String::from_utf8_lossy(&output.stderr).contains("UNVERIFIED DEVELOPER COPY"));

    fs::write(fixture.path().join("ARTIFACT-MANIFEST.txt"), b"malformed\n").unwrap();
    let output = run(
        &["copy-to-node-dev", fixture.path().to_str().unwrap(), "node-1"],
        tools.path(),
        &[("FAKE_OUT", copied.path())],
    );
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("exactly three"));
}

#[test]
fn release_check_hardcodes_symbols_and_reports_nm_failure() {
    let fixture = Fixture::new();
    let tools = tempfile::tempdir().unwrap();
    stub(tools.path(), "nm", "echo 'nm exploded' >&2\nexit 7");
    let output = run(&["release-check", fixture.path().to_str().unwrap()], tools.path(), &[]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("nm failed: nm exploded"));

    stub(tools.path(), "nm", "echo '00000000 T rs_noop'\nexit 0");
    let output = run(&["release-check", fixture.path().to_str().unwrap()], tools.path(), &[]);
    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("library exports benchmark-only symbol \"rs_noop\"")
    );

    fs::remove_file(tools.path().join("nm")).unwrap();
    let empty_path = tempfile::tempdir().unwrap();
    let output = Command::new(BINARY)
        .args(["release-check", fixture.path().to_str().unwrap()])
        .env("PATH", empty_path.path())
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("cannot execute nm"));

    fs::write(fixture.path().join("kmoney--0.1.0.sql"), b"CREATE FUNCTION rs_noop();\n").unwrap();
    let digest = hex(&Sha256::digest(fs::read(fixture.path().join("kmoney--0.1.0.sql")).unwrap()));
    let manifest_path = fixture.path().join("ARTIFACT-MANIFEST.txt");
    let manifest = fs::read_to_string(&manifest_path).unwrap();
    let mut lines = manifest.lines().map(str::to_owned).collect::<Vec<_>>();
    lines[2] = format!("{digest}  kmoney--0.1.0.sql");
    fs::write(manifest_path, format!("{}\n", lines.join("\n"))).unwrap();
    let output = run(&["release-check", fixture.path().to_str().unwrap()], tools.path(), &[]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("benchmark-only symbol \"rs_noop\""));
}

fn hex(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(encoded, "{byte:02x}").unwrap();
    }
    encoded
}

#[test]
fn successful_release_check_prints_one_stable_line() {
    let fixture = Fixture::new();
    let tools = tempfile::tempdir().unwrap();
    stub(tools.path(), "nm", "exit 0");
    let output = run(&["release-check", fixture.path().to_str().unwrap()], tools.path(), &[]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(output.stdout, b"release-checked\n");
}

#[test]
fn every_copy_failure_emits_no_receipt_and_removes_private_staging() {
    for fail_at in 1..=3 {
        let fixture = Fixture::new();
        let tools = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        stub(
            tools.path(),
            "docker",
            r#"count_file="$FAKE_OUT/count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
dirname "$2" >> "$FAKE_OUT/staging"
test "$count" -ne "$FAIL_AT""#,
        );
        let fail_at_text = fail_at.to_string();
        let old_path = std::env::var_os("PATH").unwrap_or_default();
        let mut paths = vec![tools.path().to_path_buf()];
        paths.extend(std::env::split_paths(&old_path));
        let output = Command::new(BINARY)
            .args(["copy-to-node", fixture.path().to_str().unwrap(), "node-1"])
            .env("PATH", std::env::join_paths(paths).unwrap())
            .env("FAKE_OUT", state.path())
            .env("FAIL_AT", &fail_at_text)
            .output()
            .unwrap();
        assert!(!output.status.success(), "copy {fail_at} unexpectedly passed");
        assert!(output.stdout.is_empty(), "failed copy emitted a receipt");
        let staged = fs::read_to_string(state.path().join("staging")).unwrap();
        for directory in staged.lines() {
            assert!(!Path::new(directory).exists(), "staging survived failure: {directory}");
        }
    }
}
