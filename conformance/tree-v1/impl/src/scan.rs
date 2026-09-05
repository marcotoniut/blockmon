//! A generic walk over a corpus file, independent of the typed gate harnesses: does the
//! corpus describe a wider language than CE §7 permits?
//!
//! Every object carrying a `tag` or `domain` field sets the domain context for its subtree.
//! Any `(key, record_bytes)` pair found under a context is checked against the CE §7
//! domain-state conditions; any `entries`-shaped list is checked for strict ascent.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use crate::harness::decode_hex;
use crate::record::{EncounterClass, PermitStatus, Record, Tag};
use crate::tree::{DEPTH, DomainState};

#[derive(Default)]
pub struct Scan {
    pub entries_checked: usize,
    pub lists_checked: usize,
    pub proofs_seen: usize,
    pub sibling_counts: BTreeMap<usize, usize>,
    pub statuses: BTreeSet<&'static str>,
    pub classes: BTreeSet<&'static str>,
    pub violations: Vec<String>,
    pub unlabelled_wide_shapes: Vec<String>,
}

fn tag_of(value: &Value) -> Option<Tag> {
    if let Some(name) = value.get("domain").and_then(Value::as_str) {
        return match name {
            "subject" => Some(Tag::Subject),
            "blockmon" => Some(Tag::Blockmon),
            "encounter" => Some(Tag::Encounter),
            "supply" => Some(Tag::Supply),
            _ => None,
        };
    }
    if let Some(discriminant) = value.get("tag").and_then(Value::as_u64) {
        return Tag::from_discriminant(u8::try_from(discriminant).ok()?);
    }
    // A group that carries proofs names its domain inside them.
    ["inclusion", "absence", "proof"]
        .iter()
        .find_map(|field| value.get(field).and_then(tag_of))
}

/// True when this object is a declared rejection case, where a shape the spec forbids is
/// exactly the point.
fn is_rejection(value: &Value) -> bool {
    // `kind` alone is not enough: every accepted update case carries one, and
    // treating those as rejections exempted the whole updates section.
    value.get("class").is_some() || value.get("rejection_class").is_some()
}

impl Scan {
    fn check_entry(&mut self, tag: Tag, path: &str, key_hex: &str, record_hex: &str) {
        self.entries_checked += 1;
        let key = decode_hex(key_hex);
        let record_bytes = decode_hex(record_hex);
        let mut state = DomainState::empty(tag);
        if let Err(e) = state.insert(&key, &record_bytes) {
            self.violations.push(format!("{path}: {e:?}"));
            return;
        }
        match Record::decode(tag, &record_bytes) {
            Ok(Record::Encounter(p)) => {
                self.classes.insert(match p.encounter_class {
                    EncounterClass::Common => "COMMON",
                });
                self.statuses.insert(match p.status {
                    PermitStatus::Reserved => "RESERVED",
                    PermitStatus::Consumed => "CONSUMED",
                });
            }
            Ok(Record::Supply(s)) => {
                if !s.accounting_chain_holds() {
                    self.violations.push(format!(
                        "{path}: supply record breaks created <= consumed <= minted <= envelope"
                    ));
                }
            }
            Ok(Record::Subject) => {
                if !record_bytes.is_empty() {
                    self.violations.push(format!(
                        "{path}: subject record is not the empty byte string"
                    ));
                }
            }
            Ok(Record::Blockmon(_)) => {}
            Err(e) => self.violations.push(format!("{path}: {e}")),
        }
    }

    /// Enum discriminants and record kinds actually exercised, without re-counting entries.
    fn note_record(&mut self, tag: Tag, record_bytes: &[u8]) {
        if let Ok(Record::Encounter(p)) = Record::decode(tag, record_bytes) {
            self.classes.insert(match p.encounter_class {
                EncounterClass::Common => "COMMON",
            });
            self.statuses.insert(match p.status {
                PermitStatus::Reserved => "RESERVED",
                PermitStatus::Consumed => "CONSUMED",
            });
        }
    }

    fn check_list(&mut self, tag: Tag, path: &str, items: &[Value]) {
        let pairs: Vec<(Vec<u8>, Vec<u8>)> = items
            .iter()
            .filter_map(|item| {
                let key = item.get("key")?.as_str()?;
                let record = item.get("record_bytes")?.as_str()?;
                Some((decode_hex(key), decode_hex(record)))
            })
            .collect();
        if pairs.len() != items.len() {
            return;
        }
        self.lists_checked += 1;
        for (_, record_bytes) in &pairs {
            self.note_record(tag, record_bytes);
        }
        if let Err(e) = DomainState::from_ordered(tag, &pairs) {
            self.violations
                .push(format!("{path}: ordered representation invalid: {e:?}"));
        }
    }

    fn walk(&mut self, value: &Value, path: &str, context: Option<Tag>, inherited: bool) {
        match value {
            Value::Object(map) => {
                let context = tag_of(value).or(context);
                let rejection = inherited || is_rejection(value);

                if let Some(siblings) = map.get("siblings_leaf_to_root").and_then(Value::as_array) {
                    self.proofs_seen += 1;
                    *self.sibling_counts.entry(siblings.len()).or_default() += 1;
                    if siblings.len() != DEPTH && !rejection {
                        self.unlabelled_wide_shapes.push(format!(
                            "{path}: {} siblings, not labelled a rejection",
                            siblings.len()
                        ));
                    }
                }
                if let Some(tag) = context {
                    if let (Some(Value::String(key)), Some(Value::String(record))) =
                        (map.get("key"), map.get("record_bytes"))
                    {
                        if rejection {
                            self.entries_checked += 1;
                        } else {
                            self.check_entry(tag, path, key, record);
                        }
                    }
                    for field in ["entries", "entries_before"] {
                        if let Some(items) = map.get(field).and_then(Value::as_array)
                            && !rejection
                        {
                            self.check_list(tag, &format!("{path}.{field}"), items);
                        }
                    }
                }
                if let Some(state) = map.get("state").and_then(Value::as_object) {
                    for tag in Tag::ALL {
                        if let Some(items) = state.get(tag.domain_name()).and_then(Value::as_array)
                            && items
                                .first()
                                .is_some_and(|i| i.get("record_bytes").is_some())
                        {
                            self.check_list(
                                tag,
                                &format!("{path}.state.{}", tag.domain_name()),
                                items,
                            );
                        }
                    }
                }
                for (field, child) in map {
                    self.walk(child, &format!("{path}.{field}"), context, rejection);
                }
            }
            Value::Array(items) => {
                for (i, child) in items.iter().enumerate() {
                    self.walk(child, &format!("{path}[{i}]"), context, inherited);
                }
            }
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {}
        }
    }
}

pub fn scan(doc: &Value, label: &str) -> Scan {
    let mut result = Scan::default();
    result.walk(doc, label, None, false);
    result
}
