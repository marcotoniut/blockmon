mod adversarial;
mod codec;
mod constitutional;
mod expansion;
mod harness;
mod hash;
mod proof;
mod record;
mod scan;
mod transition;
mod tree;
mod world;

use std::path::PathBuf;
use std::process::ExitCode;

use crate::tree::EmptyLadder;

// Path plumbing only, adapted when this crate was promoted out of its cleanroom
// sandbox: the constitutional and expansion paths may be given as arguments, and
// default to the repository's corpus directory.
fn vector_paths() -> (PathBuf, PathBuf) {
    let mut args = std::env::args().skip(1);
    if let (Some(a), Some(b)) = (args.next(), args.next()) {
        return (PathBuf::from(a), PathBuf::from(b));
    }
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    dir.pop();
    dir.pop();
    dir.push("vectors");
    (
        dir.join("g0a-tree-v1.json"),
        dir.join("g0a-tree-v1-expansion.json"),
    )
}

fn load(path: &PathBuf) -> serde_json::Value {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("cannot parse {}: {e}", path.display()))
}

fn main() -> ExitCode {
    let ladder = EmptyLadder::compute();
    let (constitutional_path, expansion_path) = vector_paths();
    let doc = load(&constitutional_path);
    let report = constitutional::run(&doc, &ladder);

    println!("GATE ONE  {}", constitutional_path.display());
    if !report.preamble.passed() {
        for failure in &report.preamble.failures {
            println!("  preamble  FAIL  {failure}");
        }
    }
    for check in &report.checks {
        let status = if check.passed() { "ok" } else { "FAIL" };
        println!(
            "  {status:>4}  {:<34} {} values",
            check.label, check.compared
        );
        for failure in &check.failures {
            println!("        {failure}");
        }
    }
    println!(
        "  score {}/{}  values compared {} (preamble {})",
        report.passed(),
        report.checks.len(),
        report.compared(),
        report.preamble.compared
    );

    let gate_one_clean = report.passed() == report.checks.len() && report.preamble.passed();

    println!("\nGATE TWO  {}", expansion_path.display());
    let expansion_doc = load(&expansion_path);
    let expansion = expansion::run(&expansion_doc, &ladder);
    for section in &expansion.sections {
        let status = if section.passed() { "ok" } else { "FAIL" };
        println!(
            "  {status:>4}  {:<34} {} values",
            section.label, section.compared
        );
        for failure in section.failures.iter().take(12) {
            println!("        {failure}");
        }
        if section.failures.len() > 12 {
            println!("        ... {} more", section.failures.len() - 12);
        }
    }
    println!(
        "  score {}/{} sections  values compared {}  mismatches {}",
        expansion.passed(),
        expansion.sections.len(),
        expansion.compared(),
        expansion.failures()
    );

    println!("\nSTEP FOUR  adversarial checks");
    let cases = adversarial::run(&ladder);
    let mut held = 0usize;
    for case in &cases {
        let status = if case.held { "ok" } else { "FAIL" };
        println!("  {status:>4}  {}", case.name);
        println!("        authority: {}", case.authority);
        println!("        {}", case.detail);
        held += usize::from(case.held);
    }
    println!("  {held}/{} adversarial checks hold", cases.len());

    println!("\nSTEP FOUR  corpus language scan");
    let mut scan_clean = true;
    for (label, corpus) in [("constitutional", &doc), ("expansion", &expansion_doc)] {
        let result = scan::scan(corpus, label);
        println!(
            "  {label}: {} entries, {} ordered lists, {} proofs; sibling counts {:?}",
            result.entries_checked, result.lists_checked, result.proofs_seen, result.sibling_counts
        );
        println!(
            "    encounter_class values seen {:?}, status values seen {:?}",
            result.classes, result.statuses
        );
        for violation in &result.violations {
            println!("    WIDER THAN SPEC  {violation}");
        }
        for shape in &result.unlabelled_wide_shapes {
            println!("    WIDER THAN SPEC  {shape}");
        }
        if result.violations.is_empty() && result.unlabelled_wide_shapes.is_empty() {
            println!("    nothing the spec does not permit");
        } else {
            scan_clean = false;
        }
    }

    if gate_one_clean && expansion.failures() == 0 && held == cases.len() && scan_clean {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
