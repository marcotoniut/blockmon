//! Cleanroom checker for the Transition 1 `blockmon/world/v1` corpora.

mod corpus;
mod encoding;
mod invariants;
mod kernel;
mod smt;
mod t1;
mod world;

use std::process::ExitCode;

use corpus::Tally;
use serde_json::Value;

const DEFAULT_PATHS: [&str; 2] = [
    "../../vectors/g0a-t1-v1.json",
    "../../vectors/g0a-t1-v1-expansion.json",
];

fn run(path: &str) -> Result<Tally, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    let doc: Value = serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))?;
    if doc.get("checks").is_some() {
        Ok(corpus::check_hand_tier(&doc))
    } else if doc.get("cases").is_some() {
        Ok(corpus::check_expansion(&doc))
    } else {
        Err(format!("{path}: neither `checks` nor `cases` present"))
    }
}

fn report(path: &str, t: &Tally) {
    println!("== {path}");
    println!(
        "   {} {}, {} values compared, {} mismatches, {} invariant violations, {} input errors",
        t.checks,
        t.kind,
        t.compared,
        t.mismatches.len(),
        t.invariant_failures.len(),
        t.errors.len()
    );
    println!(
        "   {} values outside the spec compared under declared readings, {} disagree (informational)",
        t.info_compared,
        t.info_mismatches.len()
    );
    println!(
        "   computed transitions, invariants asserted on each: {} created, {} roll failed, {} rejected",
        t.outcomes[1], t.outcomes[2], t.outcomes[3]
    );
    println!(
        "   {} refused by the state reader, so no outcome, commitment or transcript",
        t.refused
    );
    println!(
        "   largest computed read set {}, write set {} (not compared: no bound is pinned)",
        t.max_reads, t.max_writes
    );
    if !t.not_compared.is_empty() {
        let names: Vec<&str> = t.not_compared.iter().map(String::as_str).collect();
        println!(
            "   recorded but not compared (not defined by the spec): {}",
            names.join(", ")
        );
    }
    for m in &t.mismatches {
        println!(
            "MISMATCH {} {} computed={} recorded={}",
            m.case, m.field, m.computed, m.recorded
        );
    }
    for (case, v) in &t.invariant_failures {
        println!("INVARIANT {case} {v}");
    }
    for (case, e) in &t.errors {
        println!("INPUT-ERROR {case} {e}");
    }
    for m in &t.info_mismatches {
        println!(
            "INFO {} {} computed={} recorded={}",
            m.case, m.field, m.computed, m.recorded
        );
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let paths: Vec<&str> = if args.is_empty() {
        DEFAULT_PATHS.to_vec()
    } else {
        args.iter().map(String::as_str).collect()
    };
    let mut pass = true;
    for path in paths {
        match run(path) {
            Ok(t) => {
                report(path, &t);
                pass &= t.passed();
            }
            Err(e) => {
                println!("ERROR {e}");
                pass = false;
            }
        }
    }
    println!("RESULT: {}", if pass { "PASS" } else { "FAIL" });
    if pass {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
