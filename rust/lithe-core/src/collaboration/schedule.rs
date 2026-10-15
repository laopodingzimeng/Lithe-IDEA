//! Compiles an explicit task DAG into conservative human-accepted waves.
//!
//! The host runs disjoint AI tasks within a wave; Core keeps ownership and
//! acceptance serial between waves. This never grants an additional target.

use super::invalid;
use super::plan::{Owner, Phase, Plan, Step};
use crate::protocol::CoreError;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Every task declares its prerequisites, including an empty list for roots.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Request {
    steps: Vec<Step>,
    depends_on: BTreeMap<String, Vec<String>>,
}

/// Original task identities remain available to prompts and per-task tools.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Schedule {
    steps: Vec<Step>,
    groups: BTreeMap<String, Vec<String>>,
}

/// Stable input ordering breaks ties; shared paths and human tasks form barriers.
pub(super) fn compile(request: Request) -> Result<Schedule, CoreError> {
    let validation = Plan {
        id: "schedule-validation".into(),
        version: 1,
        requirement: "Validate task scopes".into(),
        steps: request.steps,
        current_step: 0,
        phase: Phase::Draft,
        paused: false,
    };
    validation.validate()?;
    let tasks = validation.steps;
    let ids: BTreeSet<_> = tasks.iter().map(|step| step.id.as_str()).collect();
    if request.depends_on.len() != ids.len()
        || request.depends_on.iter().any(|(id, deps)| {
            !ids.contains(id.as_str())
                || deps.len() > ids.len()
                || deps.iter().collect::<BTreeSet<_>>().len() != deps.len()
                || deps
                    .iter()
                    .any(|dep| dep == id || !ids.contains(dep.as_str()))
        })
    {
        return Err(invalid(
            "Every task needs unique known prerequisites and cannot depend on itself",
        ));
    }
    let mut completed = BTreeSet::new();
    let mut result = Schedule {
        steps: Vec::new(),
        groups: BTreeMap::new(),
    };
    while completed.len() < tasks.len() {
        let ready: Vec<_> = tasks
            .iter()
            .filter(|task| {
                !completed.contains(&task.id)
                    && request.depends_on[&task.id]
                        .iter()
                        .all(|dep| completed.contains(dep))
            })
            .collect();
        let owner = ready
            .first()
            .ok_or_else(|| invalid("Task dependencies contain a cycle"))?
            .owner;
        let mut wave = Vec::new();
        let mut paths = BTreeSet::new();
        let mut target_count = 0;
        for task in ready {
            if !wave.is_empty() && (owner == Owner::Human || task.owner == Owner::Human) {
                break;
            }
            if wave.len() == 8 {
                break;
            }
            if task
                .targets
                .iter()
                .any(|target| paths.contains(target.path()))
                || target_count + task.targets.len() > 100
            {
                continue;
            }
            for target in &task.targets {
                paths.insert(target.path().to_owned());
            }
            target_count += task.targets.len();
            wave.push(task);
        }
        let id = format!("wave-{}", result.steps.len() + 1);
        let step = Step {
            id: id.clone(),
            title: wave
                .iter()
                .map(|task| task.title.as_str())
                .collect::<Vec<_>>()
                .join(" · "),
            owner,
            targets: wave.iter().flat_map(|task| task.targets.clone()).collect(),
            acceptance: wave
                .iter()
                .flat_map(|task| {
                    task.acceptance
                        .iter()
                        .map(|text| format!("{}：{text}", task.title))
                })
                .collect(),
            questions: wave
                .iter()
                .flat_map(|task| {
                    task.questions
                        .iter()
                        .map(|text| format!("{}：{text}", task.title))
                })
                .collect(),
            decisions: wave
                .iter()
                .flat_map(|task| task.decisions.clone())
                .collect(),
        };
        let members: Vec<_> = wave.iter().map(|task| task.id.clone()).collect();
        completed.extend(members.iter().cloned());
        result.groups.insert(id, members);
        result.steps.push(step);
    }
    Ok(result)
}
