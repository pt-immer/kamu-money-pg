//! Shell-adapter controls that do not require a Docker daemon.

mod support;

use support::{Scratch, bash, lane_root};

#[test]
fn a_failed_later_copy_clears_the_previous_node_receipt() {
    let work = Scratch::new("install-receipt");
    let bin = work.directory("bin");
    let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    work.write_program(
        "bin/docker",
        &format!(
            "#!/bin/sh\n\
             if [ \"$1 $3\" = 'exec test' ]; then exit 1; fi\n\
             if [ \"$1 $3\" = 'exec sha256sum' ]; then echo '{digest}  kmoney.so'; exit 0; fi\n\
             exit 9\n"
        ),
    );
    let helper = work.write_program(
        "artifact-helper",
        &format!(
            "#!/bin/sh\n\
             [ \"$3\" != bad ] || exit 2\n\
             printf 'copied\\tverified\\t0.1.0\\t{digest}\\n'\n"
        ),
    );
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
    let script = format!(
        "source ./kamu-money-pg/yb/install.sh\n\
         YB_ARTIFACT_HELPER='{}'\n\
         yb_ensure_extension good /unused\n\
         yb_ensure_extension bad /unused && exit 91\n\
         printf '%s|%s|%s\\n' \"$YB_INSTALL_MODE\" \"$YB_INSTALL_EVIDENCE\" \"$YB_INSTALL_SHA\"\n",
        helper.display()
    );
    let outcome = bash(&lane_root(), &script, &[("PATH", Some(&path))]);
    assert_eq!(outcome.status, 0, "{}", outcome.stderr);
    assert_eq!(outcome.stdout.trim(), "||", "failed copy left stale evidence");
}
