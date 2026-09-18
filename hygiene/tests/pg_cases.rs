mod support;

use std::collections::{BTreeMap, BTreeSet};
use syn::visit::Visit;

#[derive(Debug)]
struct CoverageRow {
    case: Option<String>,
    not_portable: bool,
}

fn pg_tests() -> BTreeSet<String> {
    struct Collector<'a>(&'a mut BTreeSet<String>);

    impl<'ast> Visit<'ast> for Collector<'_> {
        fn visit_item_fn(&mut self, function: &'ast syn::ItemFn) {
            if function.attrs.iter().any(|attribute| attribute.path().is_ident("pg_test")) {
                assert!(
                    self.0.insert(function.sig.ident.to_string()),
                    "duplicate #[pg_test] name: {}",
                    function.sig.ident
                );
            }
            syn::visit::visit_item_fn(self, function);
        }
    }

    let root = support::lane_root().join("kamu-money-pg/src");
    let mut tests = BTreeSet::new();
    for path in support::rust_sources_under(&root) {
        let syntax = syn::parse_file(&support::read(&path))
            .unwrap_or_else(|error| panic!("{} must parse as Rust: {error}", path.display()));
        Collector(&mut tests).visit_file(&syntax);
    }
    assert!(tests.len() >= 50, "expected at least 50 #[pg_test] functions, found {}", tests.len());
    tests
}

fn coverage_rows(markdown: &str) -> BTreeMap<String, CoverageRow> {
    let mut rows = BTreeMap::new();
    for line in markdown.lines().filter(|line| line.starts_with('|')) {
        let cells: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
        if cells.first().and_then(|cell| cell.parse::<usize>().ok()).is_none() {
            continue;
        }
        let name = cells
            .get(1)
            .map(|cell| cell.trim_matches('`'))
            .filter(|name| !name.is_empty())
            .expect("coverage row must name a #[pg_test]")
            .to_owned();
        let not_portable = line.contains("NOT-PORTABLE:");
        let case = (!not_portable)
            .then(|| cells.get(2).map(|cell| cell.trim_matches('`').to_owned()))
            .flatten()
            .filter(|case| !case.is_empty());
        assert!(
            rows.insert(name.clone(), CoverageRow { case, not_portable }).is_none(),
            "duplicate coverage row for {name}"
        );
    }
    assert!(!rows.is_empty(), "COVERAGE.md must contain numbered rows");
    rows
}

#[test]
fn portable_case_manifest_covers_every_pg_test() {
    let root = support::lane_root();
    let suite = root.join("kamu-money-pg/tests/pg_regress");
    let coverage = support::read(suite.join("COVERAGE.md"));
    let tests = pg_tests();
    let rows = coverage_rows(&coverage);

    let covered: BTreeSet<_> = rows.keys().cloned().collect();
    let missing: Vec<_> = tests.difference(&covered).collect();
    let stale: Vec<_> = rows.keys().filter(|name| !tests.contains(*name)).collect();
    assert!(missing.is_empty(), "#[pg_test] functions missing from COVERAGE.md: {missing:?}");
    assert!(stale.is_empty(), "COVERAGE.md names removed #[pg_test] functions: {stale:?}");

    for (test, row) in &rows {
        if row.not_portable {
            continue;
        }
        let case = row.case.as_deref().unwrap_or_else(|| panic!("{test} must name a portable case"));
        assert!(
            suite.join(format!("sql/{case}.sql")).is_file()
                && suite.join(format!("expected/{case}.out")).is_file(),
            "{test} maps to {case}, but its SQL or golden file is missing"
        );
    }

    let mut labels = BTreeSet::new();
    for entry in std::fs::read_dir(suite.join("expected")).expect("expected/ must be readable") {
        let path = entry.expect("directory entry must be readable").path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("out") {
            continue;
        }
        for label in support::read(path).lines().filter_map(|line| line.strip_prefix("-- ")) {
            labels.insert(label.trim().to_owned());
        }
    }

    let unknown_labels: Vec<_> = labels.difference(&tests).collect();
    assert!(unknown_labels.is_empty(), "golden labels that are not #[pg_test] names: {unknown_labels:?}");
    let expected_labels: BTreeSet<_> =
        rows.iter().filter(|(_, row)| !row.not_portable).map(|(name, _)| name.clone()).collect();
    let missing_labels: Vec<_> = expected_labels.difference(&labels).collect();
    assert!(
        missing_labels.is_empty(),
        "portable #[pg_test] functions missing from golden labels: {missing_labels:?}"
    );

    let mapped_cases: BTreeSet<_> = rows.values().filter_map(|row| row.case.clone()).collect();
    let actual_cases: BTreeSet<_> = std::fs::read_dir(suite.join("sql"))
        .expect("sql/ must be readable")
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().and_then(|extension| extension.to_str()) == Some("sql"))
        .filter_map(|path| path.file_stem().and_then(|stem| stem.to_str()).map(str::to_owned))
        .collect();
    let orphans: Vec<_> = actual_cases.difference(&mapped_cases).collect();
    assert!(orphans.is_empty(), "SQL cases missing from COVERAGE.md: {orphans:?}");

    let exceptions = rows.values().filter(|row| row.not_portable).count();
    println!(
        "pg_regress coverage: {} tests; {} portable; {} declared exceptions",
        tests.len(),
        tests.len() - exceptions,
        exceptions
    );
}
