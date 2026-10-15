//! Pure change preparation and conservative inversion of host-recorded edits.

use super::plan::{Owner, Plan, Target};
use super::{denied, invalid, valid_path};
use crate::protocol::{cancellation, CoreError};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;
use tree_sitter::{Node, Parser};

const MAX_FILE_BYTES: usize = 2 * 1024 * 1024;
const MAX_TRANSACTION_BYTES: usize = 16 * 1024 * 1024;
const MAX_CHANGES: usize = 100;

/// Exact source snapshot supplied by the document owner, including dirty buffers.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct FileSnapshot {
    path: String,
    /// Null denotes absence; an empty string is an existing empty file.
    text: Option<String>,
}

/// A replacement for exactly one confirmed target; no fuzzy patch matching.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Change {
    target: Target,
    /// Whole-file content or complete method body, including braces.
    expected_text: Option<String>,
    replacement: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct PrepareRequest {
    plan: Plan,
    expected_version: u64,
    step_id: String,
    files: Vec<FileSnapshot>,
    changes: Vec<Change>,
}

/// Host-owned receipt. Persist only after guarded application has succeeded.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Prepared {
    plan_id: String,
    plan_version: u64,
    step_id: String,
    /// Exact inputs for compare-and-write; hosts must also check native identity.
    before: Vec<FileSnapshot>,
    after: Vec<FileSnapshot>,
    changes: Vec<Change>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ReverseRequest {
    receipt: Prepared,
    files: Vec<FileSnapshot>,
}

pub(super) fn prepare(request: PrepareRequest) -> Result<Prepared, CoreError> {
    let step = request
        .plan
        .check_ai(request.expected_version, &request.step_id)?;
    for change in &request.changes {
        if !step.targets.contains(&change.target) {
            return Err(denied("A change is outside the confirmed step scope"));
        }
    }
    // Lexically nested methods can overlap even though their symbolic targets
    // differ. Reject an outer AI scope that contains any human-owned method.
    for change in &request.changes {
        if matches!(change.target, Target::JavaMethod { .. }) {
            let source = request
                .files
                .iter()
                .find(|file| file.path == change.target.path())
                .and_then(|file| file.text.as_deref())
                .ok_or_else(|| invalid("A target snapshot is missing"))?;
            if source.len() > MAX_FILE_BYTES {
                return Err(invalid("Java source exceeds the size limit"));
            }
            let range = method_body(source, &change.target)?;
            for human in request
                .plan
                .steps
                .iter()
                .filter(|step| step.owner == Owner::Human)
            {
                for protected in &human.targets {
                    if protected.path() == change.target.path() {
                        let protected_range = method_body(source, protected)?;
                        if range.start < protected_range.end && protected_range.start < range.end {
                            return Err(denied("The AI method overlaps human-owned code"));
                        }
                    }
                }
            }
        }
    }
    let (before, after, changes) = apply(request.files, request.changes)?;
    Ok(Prepared {
        plan_id: request.plan.id,
        plan_version: request.plan.version,
        step_id: request.step_id,
        before,
        after,
        changes,
    })
}

pub(super) fn reverse(request: ReverseRequest) -> Result<Prepared, CoreError> {
    // Receipts are local trusted records, but validate their internal consistency
    // too so corrupted persistence cannot become a wider write instruction.
    let receipt = request.receipt;
    let (_, expected_after, _) = apply(receipt.before.clone(), receipt.changes.clone())?;
    if serde_json::to_value(&expected_after).ok() != serde_json::to_value(&receipt.after).ok() {
        return Err(invalid("Inconsistent collaboration receipt"));
    }
    let inverse = receipt
        .changes
        .into_iter()
        .map(|change| Change {
            target: change.target,
            expected_text: change.replacement,
            replacement: change.expected_text,
        })
        .collect();
    let (before, after, changes) = apply(request.files, inverse)?;
    Ok(Prepared {
        plan_id: receipt.plan_id,
        plan_version: receipt.plan_version,
        step_id: receipt.step_id,
        before,
        after,
        changes,
    })
}

type ChangeSet = (Vec<FileSnapshot>, Vec<FileSnapshot>, Vec<Change>);

fn apply(files: Vec<FileSnapshot>, mut changes: Vec<Change>) -> Result<ChangeSet, CoreError> {
    if files.len() > MAX_CHANGES || changes.is_empty() || changes.len() > MAX_CHANGES {
        return Err(invalid(
            "A transaction requires between one and 100 changes",
        ));
    }
    let mut sources = BTreeMap::new();
    let mut bytes = 0usize;
    for file in files {
        if !valid_path(&file.path) || sources.contains_key(&file.path) {
            return Err(invalid(
                "Snapshots must have unique normalized relative paths",
            ));
        }
        check_size(file.text.as_deref(), &mut bytes)?;
        sources.insert(file.path, file.text);
    }
    let mut targets = BTreeSet::new();
    for change in &changes {
        check_size(change.expected_text.as_deref(), &mut bytes)?;
        check_size(change.replacement.as_deref(), &mut bytes)?;
        if !valid_path(change.target.path())
            || !targets.insert(change.target.clone())
            || change.expected_text == change.replacement
        {
            return Err(invalid(
                "Changes need unique targets and must modify content",
            ));
        }
    }
    changes.sort_by(|a, b| a.target.cmp(&b.target));
    let paths: BTreeSet<_> = changes
        .iter()
        .map(|change| change.target.path().to_owned())
        .collect();
    let mut before = Vec::new();
    let mut after = Vec::new();
    for path in paths {
        cancellation::check()?;
        let source = sources
            .get(&path)
            .ok_or_else(|| invalid("A target snapshot is missing"))?;
        let local: Vec<_> = changes
            .iter()
            .filter(|change| change.target.path() == path)
            .collect();
        let replacement = if let Some(change) = local
            .iter()
            .find(|c| matches!(c.target, Target::File { .. }))
        {
            if local.len() != 1 {
                return Err(denied("Whole-file and method edits overlap"));
            }
            if &change.expected_text != source {
                return Err(denied("The target changed after generation"));
            }
            change.replacement.clone()
        } else {
            let source = source
                .as_deref()
                .ok_or_else(|| denied("The Java source no longer exists"))?;
            let mut replacements = Vec::new();
            for change in &local {
                let range = method_body(source, &change.target)?;
                if change.expected_text.as_deref() != Some(&source[range.clone()]) {
                    return Err(denied("The method changed after generation"));
                }
                let text = change
                    .replacement
                    .as_deref()
                    .ok_or_else(|| denied("Method removal needs a new scope"))?;
                replacements.push((range, text));
            }
            replacements.sort_by_key(|(range, _)| range.start);
            if replacements
                .windows(2)
                .any(|pair| pair[0].0.end > pair[1].0.start)
            {
                return Err(denied("Nested method changes overlap"));
            }
            let mut result = source.to_owned();
            for (range, text) in replacements.into_iter().rev() {
                result.replace_range(range, text);
            }
            // Braces in a replacement must not escape a method and introduce new
            // declarations. Reparse the complete result, then verify each body.
            for change in &local {
                let range = method_body(&result, &change.target)?;
                if change.replacement.as_deref() != Some(&result[range]) {
                    return Err(denied("The replacement escapes its method body"));
                }
            }
            Some(result)
        };
        if replacement
            .as_ref()
            .is_some_and(|text| text.len() > MAX_FILE_BYTES)
        {
            return Err(invalid(
                "Resulting file exceeds the collaboration size limit",
            ));
        }
        before.push(FileSnapshot {
            path: path.clone(),
            text: source.clone(),
        });
        after.push(FileSnapshot {
            path,
            text: replacement,
        });
    }
    Ok((before, after, changes))
}

fn check_size(text: Option<&str>, total: &mut usize) -> Result<(), CoreError> {
    let size = text.map_or(0, str::len);
    *total = total.saturating_add(size);
    if size > MAX_FILE_BYTES || *total > MAX_TRANSACTION_BYTES {
        return Err(invalid(
            "Collaboration source exceeds the bounded transaction size",
        ));
    }
    Ok(())
}

fn method_body(source: &str, target: &Target) -> Result<Range<usize>, CoreError> {
    let Target::JavaMethod {
        type_name,
        signature,
        ..
    } = target
    else {
        return Err(invalid("Expected a Java method target"));
    };
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_java::LANGUAGE.into())
        .map_err(|_| invalid("Java syntax parser is unavailable"))?;
    let tree = parser
        .parse(source, None)
        .ok_or_else(|| invalid("Could not parse Java source"))?;
    if tree.root_node().has_error() {
        return Err(denied(
            "Resolve Java syntax errors before applying scoped edits",
        ));
    }
    let mut cursor = tree.walk();
    let mut found = None;
    loop {
        cancellation::check()?;
        let node = cursor.node();
        if matches!(
            node.kind(),
            "method_declaration" | "constructor_declaration"
        ) {
            if let Some(body) = node.child_by_field_name("body") {
                if source[node.start_byte()..body.start_byte()].trim() == signature
                    && enclosing_types(node, source) == *type_name
                {
                    if found.is_some() {
                        return Err(denied("The Java method target is ambiguous"));
                    }
                    found = Some(body.byte_range());
                }
            }
        }
        if cursor.goto_first_child() {
            continue;
        }
        while !cursor.goto_next_sibling() {
            if !cursor.goto_parent() {
                return found
                    .ok_or_else(|| denied("The confirmed Java declaration no longer matches"));
            }
        }
    }
}

fn enclosing_types(mut node: Node<'_>, source: &str) -> String {
    let mut names = Vec::new();
    while let Some(parent) = node.parent() {
        node = parent;
        if matches!(
            node.kind(),
            "class_declaration"
                | "interface_declaration"
                | "enum_declaration"
                | "record_declaration"
        ) {
            if let Some(name) = node.child_by_field_name("name") {
                names.push(&source[name.byte_range()]);
            }
        }
        // Anonymous classes cannot be stably addressed by a lexical type path.
        if node.kind() == "object_creation_expression" {
            return String::new();
        }
    }
    names.reverse();
    names.join(".")
}
