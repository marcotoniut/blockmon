//! Comparison plumbing shared by both gates. Nothing here decides semantics; it only
//! compares recorded values against values this crate computed.

use serde_json::Value;

use crate::hash::Hash32;

pub struct Cmp {
    pub label: String,
    pub compared: usize,
    pub failures: Vec<String>,
}

impl Cmp {
    pub fn new(label: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            compared: 0,
            failures: Vec::new(),
        }
    }

    pub const fn passed(&self) -> bool {
        self.failures.is_empty()
    }

    pub fn bytes(&mut self, field: &str, recorded: &[u8], computed: &[u8]) {
        self.compared += 1;
        if recorded != computed {
            self.failures.push(format!(
                "{field}: recorded 0x{} computed 0x{}",
                hex::encode(recorded),
                hex::encode(computed)
            ));
        }
    }

    pub fn hash(&mut self, field: &str, recorded: Hash32, computed: Hash32) {
        self.bytes(field, &recorded, &computed);
    }

    pub fn text(&mut self, field: &str, recorded: &str, computed: &str) {
        self.compared += 1;
        if recorded != computed {
            self.failures.push(format!(
                "{field}: recorded {recorded:?} computed {computed:?}"
            ));
        }
    }

    pub fn flag(&mut self, field: &str, recorded: bool, computed: bool) {
        self.compared += 1;
        if recorded != computed {
            self.failures
                .push(format!("{field}: recorded {recorded} computed {computed}"));
        }
    }

    pub fn number(&mut self, field: &str, recorded: u64, computed: u64) {
        self.compared += 1;
        if recorded != computed {
            self.failures
                .push(format!("{field}: recorded {recorded} computed {computed}"));
        }
    }

    pub fn holds(&mut self, field: &str, condition: bool) {
        self.compared += 1;
        if !condition {
            self.failures.push(format!("{field}: does not hold"));
        }
    }
}

pub fn hex_bytes(value: &Value, field: &str) -> Vec<u8> {
    let text = value
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("field `{field}` is not a string"));
    decode_hex(text)
}

pub fn decode_hex(text: &str) -> Vec<u8> {
    hex::decode(text.strip_prefix("0x").unwrap_or(text))
        .unwrap_or_else(|e| panic!("field is not hex ({text}): {e}"))
}

pub fn hex_hash(value: &Value, field: &str) -> Hash32 {
    let bytes = hex_bytes(value, field);
    bytes
        .as_slice()
        .try_into()
        .unwrap_or_else(|_| panic!("field `{field}` is {} bytes, expected 32", bytes.len()))
}

pub fn hash_list(value: &Value, field: &str) -> Vec<Hash32> {
    value
        .get(field)
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("field `{field}` is not an array"))
        .iter()
        .map(|item| {
            let bytes = decode_hex(item.as_str().unwrap_or_else(|| panic!("`{field}` item")));
            bytes
                .as_slice()
                .try_into()
                .unwrap_or_else(|_| panic!("`{field}` item is not 32 bytes"))
        })
        .collect()
}

pub fn raw_hash_list(value: &Value, field: &str) -> Vec<Vec<u8>> {
    value
        .get(field)
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("field `{field}` is not an array"))
        .iter()
        .map(|item| decode_hex(item.as_str().unwrap_or_else(|| panic!("`{field}` item"))))
        .collect()
}

pub fn text_field<'a>(value: &'a Value, field: &str) -> &'a str {
    value
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("field `{field}` is not a string"))
}

pub fn u64_field(value: &Value, field: &str) -> u64 {
    value
        .get(field)
        .and_then(Value::as_u64)
        .unwrap_or_else(|| panic!("field `{field}` is not an unsigned integer"))
}

pub fn bool_field(value: &Value, field: &str) -> bool {
    value
        .get(field)
        .and_then(Value::as_bool)
        .unwrap_or_else(|| panic!("field `{field}` is not a bool"))
}

pub fn array_field<'a>(value: &'a Value, field: &str) -> &'a Vec<Value> {
    value
        .get(field)
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("field `{field}` is not an array"))
}
