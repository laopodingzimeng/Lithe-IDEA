//! Deterministic collaboration decisions; hosts own authority, storage and writes.
//!
//! These commands never grant filesystem access to an ACP process. A trusted
//! host must supply its confirmed plan and current snapshots, then apply the
//! returned changes through guarded document writes.

mod edits;
mod plan;
mod schedule;
#[cfg(test)]
mod tests;

use crate::protocol::{CoreError, ErrorCode};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;

/// Validates a proposed plan or advances a trusted, versioned plan snapshot.
pub(crate) fn transition(value: Value) -> Result<Value, CoreError> {
    encode(plan::transition(decode(value)?)?)
}

/// Prepares an atomic change set without performing any filesystem operations.
pub(crate) fn prepare(value: Value) -> Result<Value, CoreError> {
    encode(edits::prepare(decode(value)?)?)
}

/// Projects one human-owned suggestion; it never changes the plan or writes files.
pub(crate) fn preview_suggestion(value: Value) -> Result<Value, CoreError> {
    encode(edits::preview_suggestion(decode(value)?)?)
}

/// Reverses a recorded change only while its owned content is still unchanged.
pub(crate) fn reverse(value: Value) -> Result<Value, CoreError> {
    encode(edits::reverse(decode(value)?)?)
}

/// Validates dependencies and produces deterministic non-conflicting task waves.
pub(crate) fn schedule(value: Value) -> Result<Value, CoreError> {
    encode(schedule::compile(decode(value)?)?)
}

fn decode<T: DeserializeOwned>(value: Value) -> Result<T, CoreError> {
    serde_json::from_value(value).map_err(|_| invalid("Malformed collaboration request"))
}

fn encode(value: impl Serialize) -> Result<Value, CoreError> {
    serde_json::to_value(value).map_err(|_| invalid("Could not encode collaboration result"))
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn denied(message: &str) -> CoreError {
    CoreError::new(ErrorCode::PermissionDenied, message)
}

fn valid_path(path: &str) -> bool {
    !path.is_empty()
        && !path.contains(['\\', ':', '\0'])
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != ".." && part != ".git")
}
