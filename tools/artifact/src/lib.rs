//! Closed verification and byte-consuming operations for extension artifacts.

#![forbid(unsafe_code)]
#![deny(warnings, clippy::all)]

use sha2::{Digest, Sha256};
use std::fmt;
use std::fs;
use std::marker::PhantomData;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const MANIFEST_NAME: &str = "ARTIFACT-MANIFEST.txt";
const LIBRARY_NAME: &str = "kmoney.so";
const CONTROL_NAME: &str = "kmoney.control";
const LIBRARY_PATH: &str = "/home/yugabyte/postgres/lib/kmoney.so";
const EXTENSION_DIRECTORY: &str = "/home/yugabyte/postgres/share/extension";
const FORBIDDEN_SYMBOLS: [&str; 2] = ["rs_noop", "rs_noop_kmoney"];

#[derive(Debug)]
struct Unchecked;

#[derive(Debug)]
struct Verified;

#[derive(Debug)]
struct Triplet<State> {
    snapshot: Snapshot,
    manifest: Manifest,
    _state: PhantomData<State>,
}

/// An owned triplet whose manifest has not yet been checked.
#[derive(Debug)]
pub struct CandidateTriplet(Triplet<Unchecked>);

/// An owned triplet whose closed manifest and all three byte digests matched.
#[derive(Debug)]
pub struct VerifiedTriplet(Triplet<Verified>);

/// Owned bytes admitted only for a developer run with no manifest.
#[derive(Debug)]
pub struct DevelopmentTriplet {
    snapshot: Snapshot,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CopyReceipt {
    version: String,
    library_digest: String,
    evidence: Evidence,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Evidence {
    Verified,
    Unverified,
}

impl CopyReceipt {
    #[must_use]
    pub fn version(&self) -> &str {
        &self.version
    }

    #[must_use]
    pub fn library_digest(&self) -> &str {
        &self.library_digest
    }

    #[must_use]
    pub const fn evidence(&self) -> &'static str {
        match self {
            Self { evidence: Evidence::Verified, .. } => "verified",
            Self { evidence: Evidence::Unverified, .. } => "unverified",
        }
    }
}

#[derive(Debug)]
pub enum ArtifactError {
    ManifestMissing(PathBuf),
    Invalid(String),
    Io { context: String, source: std::io::Error },
    Command { program: &'static str, detail: String },
}

impl ArtifactError {
    #[must_use]
    pub const fn is_manifest_missing(&self) -> bool {
        matches!(self, Self::ManifestMissing(_))
    }

    fn io(context: impl Into<String>, source: std::io::Error) -> Self {
        Self::Io { context: context.into(), source }
    }
}

impl fmt::Display for ArtifactError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ManifestMissing(path) => write!(formatter, "{} is missing", path.display()),
            Self::Invalid(message) => formatter.write_str(message),
            Self::Io { context, source } => write!(formatter, "{context}: {source}"),
            Self::Command { program, detail } => write!(formatter, "{program} failed: {detail}"),
        }
    }
}

impl std::error::Error for ArtifactError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

#[derive(Debug)]
struct Snapshot {
    version: String,
    library: Vec<u8>,
    control: Vec<u8>,
    sql_name: String,
    sql: Vec<u8>,
}

#[derive(Debug)]
struct Manifest {
    digests: [[u8; 32]; 3],
}

impl CandidateTriplet {
    /// Reads the triplet and its mandatory manifest without issuing verification evidence.
    pub fn open(directory: impl AsRef<Path>) -> Result<Self, ArtifactError> {
        let directory = directory.as_ref();
        let snapshot = Snapshot::read(directory)?;
        let path = directory.join(MANIFEST_NAME);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(ArtifactError::ManifestMissing(path));
            }
            Err(error) => return Err(ArtifactError::io(format!("cannot read {}", path.display()), error)),
        };
        let manifest = Manifest::parse(&bytes, &snapshot.sql_name)?;
        Ok(Self(Triplet { snapshot, manifest, _state: PhantomData }))
    }

    /// Checks all three owned byte snapshots and advances to the protected verified product.
    pub fn verify(self) -> Result<VerifiedTriplet, ArtifactError> {
        let manifest = self.0.manifest;
        let actual = self.0.snapshot.digests();
        for (name, expected, got) in [
            (LIBRARY_NAME, manifest.digests[0], actual[0]),
            (CONTROL_NAME, manifest.digests[1], actual[1]),
            (&self.0.snapshot.sql_name, manifest.digests[2], actual[2]),
        ] {
            if expected != got {
                return Err(ArtifactError::Invalid(format!(
                    "MANIFEST MISMATCH for {name}: expected {}, got {}",
                    encode_digest(&expected),
                    encode_digest(&got)
                )));
            }
        }
        Ok(VerifiedTriplet(Triplet { snapshot: self.0.snapshot, manifest, _state: PhantomData }))
    }
}

impl DevelopmentTriplet {
    /// Reads an owned coherent triplet only when the manifest is absent.
    pub fn open_without_manifest(directory: impl AsRef<Path>) -> Result<Self, ArtifactError> {
        let directory = directory.as_ref();
        let manifest = directory.join(MANIFEST_NAME);
        match fs::symlink_metadata(&manifest) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Ok(_) => {
                return Err(ArtifactError::Invalid(format!(
                    "{} exists; a developer run must verify it rather than downgrade it",
                    manifest.display()
                )));
            }
            Err(error) => {
                return Err(ArtifactError::io(format!("cannot inspect {}", manifest.display()), error));
            }
        }
        Ok(Self { snapshot: Snapshot::read(directory)? })
    }
}

impl Snapshot {
    fn read(directory: &Path) -> Result<Self, ArtifactError> {
        if !directory.is_dir() {
            return Err(ArtifactError::Invalid(format!(
                "{} is not an artifact directory",
                directory.display()
            )));
        }
        let sql_names = fs::read_dir(directory)
            .map_err(|error| ArtifactError::io(format!("cannot list {}", directory.display()), error))?
            .map(|entry| entry.map_err(|error| ArtifactError::io("cannot inspect artifact entry", error)))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter_map(|entry| {
                let name = entry.file_name().into_string().ok()?;
                (name.starts_with("kmoney--") && name.ends_with(".sql")).then_some(name)
            })
            .collect::<Vec<_>>();
        if sql_names.len() != 1 {
            return Err(ArtifactError::Invalid(format!(
                "artifact directory must contain exactly one kmoney--<version>.sql; found {}",
                sql_names.len()
            )));
        }
        let sql_name = sql_names[0].clone();
        for name in [LIBRARY_NAME, CONTROL_NAME, sql_name.as_str()] {
            let path = directory.join(name);
            let metadata = fs::symlink_metadata(&path)
                .map_err(|error| ArtifactError::io(format!("cannot inspect {}", path.display()), error))?;
            if !metadata.file_type().is_file() {
                return Err(ArtifactError::Invalid(format!("{} is not a regular file", path.display())));
            }
        }
        let library = read_member(directory, LIBRARY_NAME)?;
        let control = read_member(directory, CONTROL_NAME)?;
        let sql = read_member(directory, &sql_name)?;
        let version = control_version(&control)?;
        let file_version = sql_name
            .strip_prefix("kmoney--")
            .and_then(|name| name.strip_suffix(".sql"))
            .expect("SQL selection fixes prefix and suffix");
        if version != file_version {
            return Err(ArtifactError::Invalid(format!(
                "INCOHERENT TRIPLET: {CONTROL_NAME} declares {version:?}, but {sql_name} names {file_version:?}"
            )));
        }
        Ok(Self { version, library, control, sql_name, sql })
    }

    fn digests(&self) -> [[u8; 32]; 3] {
        [digest(&self.library), digest(&self.control), digest(&self.sql)]
    }

    fn stage(&self) -> Result<(tempfile::TempDir, [PathBuf; 3]), ArtifactError> {
        let directory = tempfile::tempdir()
            .map_err(|error| ArtifactError::io("cannot create staging directory", error))?;
        let paths = [
            directory.path().join(LIBRARY_NAME),
            directory.path().join(CONTROL_NAME),
            directory.path().join(&self.sql_name),
        ];
        for ((path, bytes), mode) in
            paths.iter().zip([&self.library, &self.control, &self.sql]).zip([0o755, 0o644, 0o644])
        {
            fs::write(path, bytes)
                .map_err(|error| ArtifactError::io(format!("cannot stage {}", path.display()), error))?;
            fs::set_permissions(path, fs::Permissions::from_mode(mode)).map_err(|error| {
                ArtifactError::io(format!("cannot set staged permissions on {}", path.display()), error)
            })?;
        }
        Ok((directory, paths))
    }
}

impl Manifest {
    fn parse(bytes: &[u8], sql_name: &str) -> Result<Self, ArtifactError> {
        let text = std::str::from_utf8(bytes).map_err(|_| {
            ArtifactError::Invalid("artifact manifest is not UTF-8 GNU text format".to_owned())
        })?;
        if !text.ends_with('\n') || text.contains('\r') {
            return Err(ArtifactError::Invalid(
                "artifact manifest must use canonical LF-terminated GNU text format".to_owned(),
            ));
        }
        let lines = text.lines().collect::<Vec<_>>();
        if lines.len() != 3 {
            return Err(ArtifactError::Invalid(format!(
                "artifact manifest must contain exactly three entries; found {}",
                lines.len()
            )));
        }
        let expected_names = [LIBRARY_NAME, CONTROL_NAME, sql_name];
        let mut digests = [[0_u8; 32]; 3];
        let mut seen = [false; 3];
        for (line_number, line) in lines.iter().enumerate() {
            let Some((encoded, name)) = line.split_once("  ") else {
                return Err(ArtifactError::Invalid(format!(
                    "manifest entry {} is not canonical GNU text format",
                    line_number + 1
                )));
            };
            if name.contains(['/', '\\']) || name == "." || name == ".." {
                return Err(ArtifactError::Invalid(format!(
                    "manifest entry {} has non-canonical name {name:?}",
                    line_number + 1
                )));
            }
            let Some(index) = expected_names.iter().position(|expected| *expected == name) else {
                return Err(ArtifactError::Invalid(format!("unexpected manifest member {name:?}")));
            };
            if seen[index] {
                return Err(ArtifactError::Invalid(format!("duplicate manifest member {name:?}")));
            }
            seen[index] = true;
            digests[index] = decode_digest(encoded)?;
        }
        debug_assert!(seen.into_iter().all(|member| member));
        Ok(Self { digests })
    }
}

/// Runs the release-only checks over the bytes held by a verified product.
///
/// ```no_run
/// use kamu_money_pg_artifact::{release_check, VerifiedTriplet};
/// fn accepts(artifact: &VerifiedTriplet) {
///     release_check(artifact).unwrap();
/// }
/// ```
///
/// ```compile_fail,E0308
/// use kamu_money_pg_artifact::{release_check, CandidateTriplet};
/// fn refuses(candidate: &CandidateTriplet) {
///     release_check(candidate).unwrap();
/// }
/// ```
///
/// ```compile_fail,E0308
/// use kamu_money_pg_artifact::{release_check, DevelopmentTriplet};
/// fn refuses(development: &DevelopmentTriplet) {
///     release_check(development).unwrap();
/// }
/// ```
///
/// ```compile_fail,E0423
/// use kamu_money_pg_artifact::VerifiedTriplet;
/// let forged = VerifiedTriplet;
/// ```
pub fn release_check(artifact: &VerifiedTriplet) -> Result<(), ArtifactError> {
    for symbol in FORBIDDEN_SYMBOLS {
        if contains_ascii_case_insensitive(&artifact.0.snapshot.sql, symbol.as_bytes()) {
            return Err(ArtifactError::Invalid(format!(
                "release artifact SQL contains benchmark-only symbol {symbol:?}"
            )));
        }
    }
    let (_staging, paths) = artifact.0.snapshot.stage()?;
    let output = Command::new("nm")
        .args(["-D", "--defined-only"])
        .arg(&paths[0])
        .output()
        .map_err(|error| ArtifactError::io("cannot execute nm", error))?;
    if !output.status.success() {
        return Err(ArtifactError::Command {
            program: "nm",
            detail: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    for symbol in FORBIDDEN_SYMBOLS {
        if contains_ascii_case_insensitive(&output.stdout, symbol.as_bytes()) {
            return Err(ArtifactError::Invalid(format!(
                "release artifact library exports benchmark-only symbol {symbol:?}"
            )));
        }
    }
    Ok(())
}

pub fn copy_to_node(artifact: &VerifiedTriplet, node: &str) -> Result<CopyReceipt, ArtifactError> {
    copy_snapshot(&artifact.0.snapshot, node, Evidence::Verified, artifact.0.manifest.digests[0])
}

pub fn copy_development_to_node(
    artifact: &DevelopmentTriplet,
    node: &str,
) -> Result<CopyReceipt, ArtifactError> {
    let library_digest = digest(&artifact.snapshot.library);
    copy_snapshot(&artifact.snapshot, node, Evidence::Unverified, library_digest)
}

fn copy_snapshot(
    snapshot: &Snapshot,
    node: &str,
    evidence: Evidence,
    library_digest: [u8; 32],
) -> Result<CopyReceipt, ArtifactError> {
    if node.is_empty() || node.starts_with('-') {
        return Err(ArtifactError::Invalid("container name is empty or option-like".to_owned()));
    }
    let (_staging, paths) = snapshot.stage()?;
    let destinations = [
        format!("{node}:{LIBRARY_PATH}"),
        format!("{node}:{EXTENSION_DIRECTORY}/{CONTROL_NAME}"),
        format!("{node}:{EXTENSION_DIRECTORY}/{}", snapshot.sql_name),
    ];
    for (path, destination) in paths.iter().zip(destinations) {
        let status = Command::new("docker")
            .arg("cp")
            .arg(path)
            .arg(&destination)
            .stdout(Stdio::null())
            .status()
            .map_err(|error| ArtifactError::io("cannot execute docker cp", error))?;
        if !status.success() {
            return Err(ArtifactError::Command {
                program: "docker cp",
                detail: format!("copy to {destination} exited with {status}"),
            });
        }
    }
    Ok(CopyReceipt {
        version: snapshot.version.clone(),
        library_digest: encode_digest(&library_digest),
        evidence,
    })
}

fn read_member(directory: &Path, name: &str) -> Result<Vec<u8>, ArtifactError> {
    let path = directory.join(name);
    fs::read(&path).map_err(|error| ArtifactError::io(format!("cannot read {}", path.display()), error))
}

fn control_version(control: &[u8]) -> Result<String, ArtifactError> {
    let text = std::str::from_utf8(control)
        .map_err(|_| ArtifactError::Invalid(format!("{CONTROL_NAME} is not UTF-8")))?;
    let versions = text
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            (key.trim() == "default_version").then(|| value.trim())
        })
        .collect::<Vec<_>>();
    if versions.len() != 1 {
        return Err(ArtifactError::Invalid(format!(
            "{CONTROL_NAME} must declare default_version exactly once"
        )));
    }
    let value = versions[0];
    let Some(quoted) = value.strip_prefix('\'') else {
        return Err(ArtifactError::Invalid(format!("{CONTROL_NAME} has invalid default_version")));
    };
    let Some(end) = quoted.find('\'') else {
        return Err(ArtifactError::Invalid(format!("{CONTROL_NAME} has invalid default_version")));
    };
    let (version, trailing) = quoted.split_at(end);
    let trailing = trailing[1..].trim();
    if version.is_empty() || (!trailing.is_empty() && !trailing.starts_with('#')) {
        return Err(ArtifactError::Invalid(format!("{CONTROL_NAME} has invalid default_version")));
    }
    if !version.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+' | b'_'))
    {
        return Err(ArtifactError::Invalid(format!("{CONTROL_NAME} has unsafe default_version {version:?}")));
    }
    Ok(version.to_owned())
}

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn decode_digest(encoded: &str) -> Result<[u8; 32], ArtifactError> {
    if encoded.len() != 64
        || !encoded.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(ArtifactError::Invalid(format!("invalid canonical SHA-256 digest {encoded:?}")));
    }
    let mut decoded = [0_u8; 32];
    for (index, pair) in encoded.as_bytes().chunks_exact(2).enumerate() {
        decoded[index] = (hex_nibble(pair[0]) << 4) | hex_nibble(pair[1]);
    }
    Ok(decoded)
}

fn hex_nibble(byte: u8) -> u8 {
    match byte {
        b'0'..=b'9' => byte - b'0',
        b'a'..=b'f' => byte - b'a' + 10,
        _ => unreachable!("digest validation admits only lowercase hex"),
    }
}

fn encode_digest(digest: &[u8; 32]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(64);
    for byte in digest {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
}

fn contains_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window.eq_ignore_ascii_case(needle))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> tempfile::TempDir {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join(LIBRARY_NAME), b"ELF-not-really\n").unwrap();
        fs::write(directory.path().join(CONTROL_NAME), b"default_version = '0.1.0'\n").unwrap();
        fs::write(directory.path().join("kmoney--0.1.0.sql"), b"CREATE TYPE kmoney;\n").unwrap();
        write_manifest(directory.path(), &[LIBRARY_NAME, CONTROL_NAME, "kmoney--0.1.0.sql"]);
        directory
    }

    fn write_manifest(directory: &Path, names: &[&str]) {
        let text = names
            .iter()
            .map(|name| {
                let bytes = fs::read(directory.join(name)).unwrap_or_default();
                format!("{}  {name}\n", encode_digest(&digest(&bytes)))
            })
            .collect::<String>();
        fs::write(directory.join(MANIFEST_NAME), text).unwrap();
    }

    #[test]
    fn complete_manifest_mints_verified_triplet() {
        let directory = fixture();
        CandidateTriplet::open(directory.path()).unwrap().verify().unwrap();
    }

    #[test]
    fn complete_manifest_accepts_reordered_members() {
        let directory = fixture();
        write_manifest(directory.path(), &[CONTROL_NAME, "kmoney--0.1.0.sql", LIBRARY_NAME]);
        CandidateTriplet::open(directory.path()).unwrap().verify().unwrap();
    }

    #[test]
    fn control_version_accepts_a_trailing_comment() {
        let directory = fixture();
        fs::write(directory.path().join(CONTROL_NAME), b"default_version = '0.1.0' # packaged version\n")
            .unwrap();
        write_manifest(directory.path(), &[LIBRARY_NAME, CONTROL_NAME, "kmoney--0.1.0.sql"]);
        CandidateTriplet::open(directory.path()).unwrap().verify().unwrap();
    }

    #[test]
    fn partial_duplicate_extra_and_path_manifest_entries_are_refused() {
        for (names, expected) in [
            (vec![CONTROL_NAME], "exactly three"),
            (vec![LIBRARY_NAME, CONTROL_NAME, CONTROL_NAME], "duplicate manifest member"),
            (vec![LIBRARY_NAME, CONTROL_NAME, "kmoney--0.1.0.sql", LIBRARY_NAME], "exactly three"),
            (vec![LIBRARY_NAME, CONTROL_NAME, "../kmoney--0.1.0.sql"], "non-canonical name"),
        ] {
            let directory = fixture();
            write_manifest(directory.path(), &names);
            let error = CandidateTriplet::open(directory.path()).unwrap_err().to_string();
            assert!(error.contains(expected), "wrong refusal for {names:?}: {error}");
        }
    }

    #[test]
    fn malformed_digest_and_binary_marker_are_refused() {
        let directory = fixture();
        let path = directory.path().join(MANIFEST_NAME);
        let original = fs::read_to_string(&path).unwrap();
        fs::write(&path, original.replacen("  kmoney.so", " *kmoney.so", 1)).unwrap();
        assert!(CandidateTriplet::open(directory.path()).is_err());

        fs::write(&path, original.replacen(|character: char| character.is_ascii_hexdigit(), "G", 1)).unwrap();
        assert!(CandidateTriplet::open(directory.path()).is_err());
    }

    #[test]
    fn changed_byte_fails_verification() {
        let directory = fixture();
        fs::write(directory.path().join(LIBRARY_NAME), b"substituted\n").unwrap();
        let error = CandidateTriplet::open(directory.path()).unwrap().verify().unwrap_err();
        assert!(error.to_string().contains("MANIFEST MISMATCH"));
    }

    #[test]
    fn version_skew_and_multiple_scripts_are_refused() {
        let directory = fixture();
        fs::write(directory.path().join(CONTROL_NAME), b"default_version = '0.2.0'\n").unwrap();
        let error = CandidateTriplet::open(directory.path()).unwrap_err().to_string();
        assert!(error.contains("INCOHERENT TRIPLET"), "wrong refusal: {error}");

        let directory = fixture();
        fs::write(directory.path().join("kmoney--0.2.0.sql"), b"SELECT 1;\n").unwrap();
        let error = CandidateTriplet::open(directory.path()).unwrap_err().to_string();
        assert!(error.contains("exactly one") && error.contains("found 2"), "wrong refusal: {error}");
    }

    #[test]
    fn absent_manifest_is_dev_only_but_present_bad_manifest_never_downgrades() {
        let directory = fixture();
        fs::remove_file(directory.path().join(MANIFEST_NAME)).unwrap();
        let error = CandidateTriplet::open(directory.path()).unwrap_err();
        assert!(error.is_manifest_missing());
        DevelopmentTriplet::open_without_manifest(directory.path()).unwrap();

        fs::write(directory.path().join(MANIFEST_NAME), b"bad\n").unwrap();
        assert!(DevelopmentTriplet::open_without_manifest(directory.path()).is_err());
    }

    #[test]
    fn verified_snapshot_survives_source_mutation() {
        let directory = fixture();
        let verified = CandidateTriplet::open(directory.path()).unwrap().verify().unwrap();
        fs::write(directory.path().join(LIBRARY_NAME), b"later mutation\n").unwrap();
        let (_staging, paths) = verified.0.snapshot.stage().unwrap();
        assert_eq!(fs::read(&paths[0]).unwrap(), b"ELF-not-really\n");
    }

    #[test]
    fn missing_member_and_directory_are_refused() {
        for (name, expected) in [
            (LIBRARY_NAME, LIBRARY_NAME),
            (CONTROL_NAME, CONTROL_NAME),
            ("kmoney--0.1.0.sql", "exactly one kmoney--<version>.sql"),
        ] {
            let directory = fixture();
            fs::remove_file(directory.path().join(name)).unwrap();
            let error = CandidateTriplet::open(directory.path()).unwrap_err().to_string();
            assert!(error.contains(expected), "wrong refusal after removing {name}: {error}");
        }
        let directory = tempfile::tempdir().unwrap();
        let absent = directory.path().join("absent");
        let error = CandidateTriplet::open(&absent).unwrap_err().to_string();
        assert!(error.contains("is not an artifact directory"), "wrong refusal: {error}");
    }

    #[test]
    fn nested_triplet_is_not_resolved_from_parent_directory() {
        let parent = tempfile::tempdir().unwrap();
        let nested = parent.path().join("nested");
        fs::create_dir(&nested).unwrap();
        fs::write(nested.join(LIBRARY_NAME), b"nested").unwrap();
        fs::write(nested.join(CONTROL_NAME), b"default_version = '0.1.0'\n").unwrap();
        fs::write(nested.join("kmoney--0.1.0.sql"), b"SELECT 1;\n").unwrap();
        write_manifest(&nested, &[LIBRARY_NAME, CONTROL_NAME, "kmoney--0.1.0.sql"]);
        CandidateTriplet::open(&nested).unwrap().verify().unwrap();
        let error = CandidateTriplet::open(parent.path()).unwrap_err().to_string();
        assert!(error.contains("found 0"), "resolver searched recursively: {error}");
    }
}
