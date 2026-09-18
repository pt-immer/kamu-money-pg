mod support;

fn outside_quotes(source: &str) -> String {
    let mut output = String::with_capacity(source.len());
    let mut chars = source.chars();
    let mut quote = None;
    while let Some(character) = chars.next() {
        match quote {
            None => match character {
                '\'' | '"' => quote = Some(character),
                _ => output.push(character),
            },
            Some('"') if character == '\\' => {
                chars.next();
            }
            Some(active) if character == active => quote = None,
            Some(_) => {}
        }
    }
    output
}

fn merges_docker_exec_streams_on_host(logical_line: &str) -> bool {
    let command_position = logical_line.match_indices("docker exec").any(|(index, _)| {
        logical_line[..index]
            .trim_end()
            .chars()
            .next_back()
            .is_none_or(|character| !matches!(character, '"' | '\''))
    });
    if !command_position {
        return false;
    }
    let shell = outside_quotes(logical_line);
    shell.contains("2>&1") && !shell.contains("/dev/null")
}

fn logical_lines(source: &str) -> Vec<(usize, String)> {
    let mut lines = Vec::new();
    let mut logical = String::new();
    let mut start = 0;
    for (index, line) in source.lines().enumerate() {
        if logical.is_empty() {
            start = index + 1;
        }
        logical.push_str(line.strip_suffix('\\').unwrap_or(line));
        if !line.ends_with('\\') {
            lines.push((start, std::mem::take(&mut logical)));
        }
    }
    if !logical.is_empty() {
        lines.push((start, logical));
    }
    lines
}

#[test]
fn docker_exec_streams_are_merged_inside_the_container() {
    for bad in [
        r#"docker exec "$NODE" ysqlsh -c 'SELECT 1' > "$OUT" 2>&1"#,
        r#"docker exec node bash -c 'command' >output 2>&1"#,
    ] {
        assert!(merges_docker_exec_streams_on_host(bad), "must reject host merge: {bad}");
    }
    for good in [
        r#"docker exec "$NODE" bash -c 'exec ysqlsh "$@" 2>&1' x -c 'SELECT 1'"#,
        r#"docker exec "$NODE" pg_isready >/dev/null 2>&1"#,
        r#"./run.sh --server-exec "docker exec -i $NODE bash" > "$LOG" 2>&1"#,
    ] {
        assert!(!merges_docker_exec_streams_on_host(good), "must accept source merge: {good}");
    }

    let root = support::lane_root();
    let mut offenders = Vec::new();
    for relative in support::tracked_files(Some("*.sh")) {
        for (line, logical) in logical_lines(&support::read(root.join(&relative))) {
            if merges_docker_exec_streams_on_host(&logical) {
                offenders.push(format!("{}:{line}: {}", relative.display(), logical.trim()));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "docker exec output must merge at the source, before Docker multiplexes streams:\n{}",
        offenders.join("\n")
    );
}

fn teaches_named_just_argument(arguments: &str) -> bool {
    arguments.split_whitespace().any(|token| {
        let token = token.trim_start_matches(['`', '\'', '"', '(']);
        let Some((name, _)) = token.split_once('=') else {
            return false;
        };
        !name.is_empty()
            && name.starts_with(|character: char| character.is_ascii_lowercase() || character == '_')
            && name.chars().all(|character| {
                character.is_ascii_lowercase() || character.is_ascii_digit() || character == '_'
            })
    })
}

#[test]
fn documentation_uses_positional_just_arguments() {
    const MARKER: &str = "just-anti-example";

    let root = support::lane_root();
    let dump = support::just_dump(&root);
    let recipes: Vec<_> = dump["recipes"]
        .as_object()
        .expect("just dump must contain recipes")
        .keys()
        .map(String::as_str)
        .collect();
    assert!(recipes.len() > 10, "positive control: Justfile must define recipes");

    let mut offenders = Vec::new();
    for relative in support::tracked_files(None) {
        if relative.ends_with("hygiene/tests/scripts.rs") {
            continue;
        }
        let path = root.join(&relative);
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        let lines: Vec<_> = text.lines().collect();
        for (index, line) in lines.iter().enumerate() {
            if line.contains(MARKER)
                || index.checked_sub(1).is_some_and(|previous| lines[previous].contains(MARKER))
            {
                continue;
            }
            for recipe in &recipes {
                let needle = format!("just {recipe} ");
                for (start, _) in line.match_indices(&needle) {
                    if teaches_named_just_argument(&line[start + needle.len()..]) {
                        offenders.push(format!("{}:{}: {}", relative.display(), index + 1, line.trim()));
                    }
                }
            }
        }
    }
    offenders.sort();
    offenders.dedup();
    assert!(
        offenders.is_empty(),
        "just recipe arguments are positional; replace `name=value` call syntax:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn benchmark_runners_print_only_a_host_digest() {
    let directory = support::lane_root().join("kamu-money-pg/bench");
    for entry in std::fs::read_dir(directory).expect("bench/ must be readable") {
        let path = entry.expect("directory entry must be readable").path();
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        if !name.starts_with("run-bench-") || !name.ends_with(".sh") {
            continue;
        }
        let source = support::read(&path);
        assert!(source.contains("host id"), "{name} must print a non-identifying host digest");
        for (index, line) in source.lines().enumerate() {
            let raw_identity = line.trim_start().starts_with("echo")
                && (line.contains("uname") || line.contains("model name"))
                && !line.contains("sha256sum");
            assert!(!raw_identity, "{name}:{} prints raw host identity", index + 1);
        }
    }
}

fn without_command_substitutions(line: &str) -> String {
    let characters: Vec<_> = line.chars().collect();
    let mut output = String::with_capacity(line.len());
    let mut depth = 0;
    let mut index = 0;
    while index < characters.len() {
        if characters[index] == '$' && characters.get(index + 1) == Some(&'(') {
            depth += 1;
            index += 2;
            continue;
        }
        if depth > 0 && characters[index] == ')' {
            depth -= 1;
            index += 1;
            continue;
        }
        if depth == 0 {
            output.push(characters[index]);
        }
        index += 1;
    }
    output
}

fn shifts_after_empty_parameter(line: &str, empty_parameters: &[String]) -> bool {
    let line = without_command_substitutions(line);
    let trimmed = line.trim_start();
    if !(trimmed.starts_with("./") || trimmed.contains(".sh ")) {
        return false;
    }
    empty_parameters.iter().any(|parameter| {
        let needle = format!("{{{{ {parameter} }}}}");
        let Some(index) = line.find(&needle) else {
            return false;
        };
        let quoted = line[..index].trim_end().ends_with('"')
            && line[index + needle.len()..].trim_start().starts_with('"');
        !quoted && !line[index + needle.len()..].trim().is_empty()
    })
}

#[test]
fn empty_recipe_parameters_cannot_shift_later_arguments() {
    let tag = vec!["tag".to_owned()];
    assert!(shifts_after_empty_parameter("./run.sh {{ tag }} fixture.sql", &tag));
    assert!(!shifts_after_empty_parameter("./run.sh \"{{ tag }}\" fixture.sql", &tag));
    assert!(!shifts_after_empty_parameter("./run.sh {{ tag }}", &tag));

    let dump = support::just_dump(&support::lane_root());
    let names: Vec<_> =
        dump["recipes"].as_object().expect("just dump must contain recipes").keys().cloned().collect();
    let mut checked = 0;
    let mut offenders = Vec::new();
    for name in names {
        let empty = support::recipe_empty_parameters(&dump, &name);
        if empty.is_empty() {
            continue;
        }
        checked += 1;
        for line in support::recipe_body(&dump, &name).lines() {
            if shifts_after_empty_parameter(line, &empty) {
                offenders.push(format!("{name}: {}", line.trim()));
            }
        }
    }
    assert!(checked > 0, "positive control: at least one recipe must have an empty default");
    assert!(
        offenders.is_empty(),
        "quote empty recipe parameters when later arguments follow:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn shared_scratch_scripts_take_the_workspace_lock() {
    let root = support::lane_root();
    let scripts = support::tracked_files(Some("*.sh"));
    let sourced_libraries = ["artifact.sh", "cluster.sh", "install.sh"];
    let mut seen_libraries = Vec::new();
    let mut offenders = Vec::new();

    for relative in &scripts {
        let source = support::read(root.join(relative));
        if !source.contains("kamu-money-pg/yb/out") {
            continue;
        }
        let name = relative.file_name().and_then(|name| name.to_str()).unwrap_or_default();
        if sourced_libraries.contains(&name) {
            seen_libraries.push(name.to_owned());
        } else if !source.contains("workspace_lock") {
            offenders.push(relative.display().to_string());
        }
    }
    assert!(
        offenders.is_empty(),
        "shared-scratch entry points missing workspace_lock:\n{}",
        offenders.join("\n")
    );

    for library in sourced_libraries {
        assert!(
            seen_libraries.iter().any(|seen| seen == library),
            "remove stale sourced-library exemption for {library}"
        );
        assert!(
            scripts.iter().any(|relative| {
                !relative.ends_with(library)
                    && support::read(root.join(relative)).contains(&format!("/{library}"))
            }),
            "{library} is exempt as a sourced library but no script sources it"
        );
    }
}
