mod support;

use serde_json::Value;
use std::collections::BTreeSet;
use support::{lane_root, read};

fn yaml(path: &str) -> Value {
    yaml_serde::from_str(&read(lane_root().join(path))).expect("workflow must parse")
}

#[test]
fn the_required_check_gathers_every_job_without_skips() {
    let workflow = yaml(".github/workflows/on-pr-synced.yml");
    let jobs = workflow["jobs"].as_object().unwrap();
    let expected: BTreeSet<_> =
        jobs.keys().filter(|name| *name != "ci-success").map(String::as_str).collect();
    let actual: BTreeSet<_> =
        jobs["ci-success"]["needs"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    assert_eq!(actual, expected);
    assert_eq!(jobs["ci-success"]["if"], "${{ always() }}");
    for (name, job) in jobs {
        if name != "ci-success" {
            assert!(job.get("if").is_none(), "{name} must run on every PR");
        }
        for step in job["steps"].as_array().unwrap() {
            assert!(step.get("with").and_then(|v| v.get("allowed-skips")).is_none());
        }
    }
    assert!(workflow["on"]["pull_request"].get("paths").is_none());
}

#[test]
fn workflows_run_real_recipes_and_pin_remote_actions() {
    let dump = support::just_dump(&lane_root());
    let recipes = dump["recipes"].as_object().unwrap();
    for path in support::tracked_files(Some(".github/workflows/*.yml")) {
        let workflow: Value = yaml_serde::from_str(&read(lane_root().join(&path))).unwrap();
        for job in workflow["jobs"].as_object().unwrap().values() {
            for step in job["steps"].as_array().unwrap() {
                if let Some(uses) = step["uses"].as_str().filter(|uses| !uses.starts_with("./")) {
                    let (_, revision) = uses.split_once('@').expect("remote action must pin a commit");
                    assert_eq!(revision.len(), 40, "{uses}");
                    assert!(revision.bytes().all(|c| c.is_ascii_hexdigit()));
                }
                if let Some(run) = step["run"].as_str() {
                    for line in run.lines() {
                        if let Some(call) = line.trim().strip_prefix("just ") {
                            let name = call.split_whitespace().next().unwrap();
                            assert!(recipes.contains_key(name), "{}: no recipe {name}", path.display());
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn toolchain_manifest_describes_the_actual_compiler_and_components() {
    let tools: Value = serde_json::from_str(&read(lane_root().join(".config/dev-tools.json"))).unwrap();
    let rust = support::manifest(lane_root().join("rust-toolchain.toml"));
    assert_eq!(tools["rust"]["primary"].as_str(), rust["toolchain"]["channel"].as_str());
    let components: BTreeSet<_> =
        rust["toolchain"]["components"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    let declared: BTreeSet<_> =
        tools["rust"]["primary_components"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    assert_eq!(components, declared);
    assert!(components.contains("rust-src"));
    let normalize = |version: &str| {
        let mut parts: Vec<u32> = version.split('.').map(|part| part.parse().unwrap()).collect();
        parts.resize(3, 0);
        parts
    };
    let manifest = support::manifest(lane_root().join("Cargo.toml"));
    assert_eq!(
        normalize(tools["rust"]["msrv"].as_str().unwrap()),
        normalize(manifest["workspace"]["package"]["rust-version"].as_str().unwrap())
    );
}

#[test]
fn builder_inputs_trigger_publication_and_preserve_source_identity() {
    let path = ".github/workflows/publish-builder-image.yml";
    let workflow = yaml(path);
    let triggers: BTreeSet<_> =
        workflow["on"]["push"]["paths"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    let steps = workflow["jobs"]["publish"]["steps"].as_array().unwrap();
    let derive = steps.iter().find(|step| step["id"] == "image").unwrap();
    let expression = derive["env"]["INPUTS_HASH"].as_str().unwrap();
    let args = expression.split_once("hashFiles(").unwrap().1.split_once(')').unwrap().0;
    for input in args.split(',').map(|v| v.trim().trim_matches('\'')) {
        assert!(triggers.contains(input), "hashed input {input} must trigger its builder");
    }
    let publish = steps.iter().find(|step| step["id"] == "publish").unwrap();
    let run = publish["run"].as_str().unwrap();
    assert!(run.contains("org.opencontainers.image.source="));
    assert!(run.contains("containerimage.digest"));
    assert_eq!(publish["env"]["SOURCE"], "${{ github.server_url }}/${{ github.repository }}");
}

#[test]
fn dependency_cache_key_covers_every_dependency_layer_script() {
    let workflow = read(lane_root().join(".github/workflows/on-pr-synced.yml"));
    for file in ["scripts/assert-core-resolution.sh", "scripts/resolve-core-manifest.sh"] {
        assert!(workflow.contains(&format!("'{file}'")), "cache key must include {file}");
        for dockerfile in ["kamu-money-pg/Dockerfile", "kamu-money-pg/yb/Dockerfile"] {
            let docker = read(lane_root().join(dockerfile));
            assert!(
                docker.lines().any(|line| line.starts_with("COPY ") && line.contains(file)),
                "{dockerfile} must copy {file} before resolution"
            );
        }
    }
}

#[test]
fn source_policy_refuses_unstable_hash_construction() {
    use syn::visit::Visit;
    #[derive(Default)]
    struct Hasher(bool);
    impl<'a> Visit<'a> for Hasher {
        fn visit_path(&mut self, path: &'a syn::Path) {
            let names: Vec<_> = path.segments.iter().map(|part| part.ident.to_string()).collect();
            self.0 |= names.windows(2).any(|pair| pair == ["DefaultHasher", "new"]);
            syn::visit::visit_path(self, path);
        }
    }
    let check = |text: &str| {
        let mut visitor = Hasher::default();
        visitor.visit_file(&syn::parse_file(text).unwrap());
        visitor.0
    };
    assert!(check("fn f() { let _ = std::collections::hash_map::DefaultHasher::new(); }"));
    assert!(!check("// DefaultHasher::new()\nfn f() {}"));
    for path in support::tracked_files(Some("*.rs")) {
        assert!(!check(&read(lane_root().join(&path))), "{} constructs an unstable hasher", path.display());
    }
}

#[test]
fn each_ci_job_installs_the_tools_reached_by_its_recipes() {
    fn closure(name: &str, dump: &Value, reached: &mut BTreeSet<String>) {
        if !reached.insert(name.to_owned()) {
            return;
        }
        for dep in dump["recipes"][name]["dependencies"].as_array().unwrap() {
            closure(dep["recipe"].as_str().unwrap(), dump, reached);
        }
    }
    let dump = support::just_dump(&lane_root());
    let tools: Value = serde_json::from_str(&read(lane_root().join(".config/dev-tools.json"))).unwrap();
    let workflow = yaml(".github/workflows/on-pr-synced.yml");
    for (name, job) in workflow["jobs"].as_object().unwrap() {
        let mut reached = BTreeSet::new();
        let steps = job["steps"].as_array().unwrap();
        let mut installed = String::new();
        for step in steps {
            if let Some(request) = step["with"]["tool"].as_str() {
                installed.push_str(request);
            }
            if let Some(run) = step["run"].as_str() {
                for line in run.lines() {
                    if let Some(call) = line.trim().strip_prefix("just ") {
                        closure(call.split_whitespace().next().unwrap(), &dump, &mut reached);
                    }
                }
            }
        }
        let body =
            reached.iter().map(|recipe| support::recipe_body(&dump, recipe)).collect::<Vec<_>>().join("\n");
        for (tool, pin) in tools["cargo_tools"].as_object().unwrap() {
            let binary = pin["binary"].as_str().unwrap_or(tool);
            let invocation = binary.strip_prefix("cargo-").map(|sub| format!("cargo {sub}"));
            if body.contains(binary) || invocation.as_ref().is_some_and(|form| body.contains(form)) {
                assert!(
                    installed.contains(&format!("cargo_tools['{tool}']")),
                    "{name} runs {tool} without installing its pin"
                );
            }
        }
    }
}

#[test]
fn documented_recipes_exist_in_this_repository() {
    fn calls(markdown: &str) -> Vec<String> {
        markdown
            .split('`')
            .skip(1)
            .step_by(2)
            .flat_map(|code| {
                code.split_whitespace()
                    .collect::<Vec<_>>()
                    .windows(2)
                    .filter(|pair| pair[0] == "just")
                    .map(|pair| pair[1].trim_matches(['\'', '"', '(', ')', '.', ',']).to_owned())
                    .filter(|name| name.starts_with(|c: char| c.is_ascii_lowercase()))
                    .collect::<Vec<_>>()
            })
            .collect()
    }
    assert_eq!(calls("Run `just missing`.\n```bash\njust gate\n```"), ["missing", "gate"]);
    assert!(calls("the crate it just published").is_empty());
    let dump = support::just_dump(&lane_root());
    let recipes = dump["recipes"].as_object().unwrap();
    let mut checked = 0;
    for file in support::tracked_files(Some("*.md")) {
        if file.file_name().is_some_and(|name| name == "CHANGELOG.md") {
            continue;
        }
        for name in calls(&read(lane_root().join(&file))) {
            checked += 1;
            assert!(recipes.contains_key(&name), "{}: unknown recipe {name}", file.display());
        }
    }
    assert!(checked > 10);
}

#[test]
fn tooling_refuses_unreadable_inputs_instead_of_reporting_clean() {
    let scratch = support::Scratch::new("tool-failures");
    scratch.write("Justfile", &read(lane_root().join("Justfile")));
    let scrub = support::run("just", &["scrub"], scratch.path(), &[]);
    assert!(!scrub.succeeded());
    assert!(scrub.output().contains("could not scan tracked files"));
    scratch.write_program("scripts/dev-tools.sh", &read(lane_root().join("scripts/dev-tools.sh")));
    scratch.write(".config/dev-tools.json", "not JSON");
    let doctor = support::run("bash", &["scripts/dev-tools.sh", "doctor"], scratch.path(), &[]);
    assert!(!doctor.succeeded());
}

#[test]
fn yugabyte_images_install_the_registry_resolvers_jq_dependency() {
    for file in ["kamu-money-pg/yb/Dockerfile", "kamu-money-pg/yb/Dockerfile.pg15"] {
        let source = read(lane_root().join(file));
        for manager in ["dnf", "yum"] {
            let install =
                source.lines().find(|line| line.contains(&format!("{manager} install -y"))).unwrap();
            assert!(install.split_whitespace().any(|word| word == "jq"), "{file}: {manager} must install jq");
        }
    }
}
