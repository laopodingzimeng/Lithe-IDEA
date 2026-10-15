//! Versioned human/AI handoffs; completion is a human decision, never model output.

use super::{denied, invalid, valid_path};
use crate::protocol::CoreError;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// An immutable identity for one confirmed edit target.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(super) enum Target {
    /// A whole file, including an explicitly authorized new file.
    File { path: String },
    /// Only the body of one existing Java method; its declaration is protected.
    JavaMethod {
        path: String,
        /// Lexical enclosing type names, outermost first (for example Outer.Inner).
        #[serde(rename = "typeName")]
        type_name: String,
        /// Exact declaration text before the body, trimmed at both ends.
        signature: String,
    },
}

impl Target {
    pub(super) fn path(&self) -> &str {
        match self {
            Self::File { path } | Self::JavaMethod { path, .. } => path,
        }
    }

    fn validate(&self) -> Result<(), CoreError> {
        if !valid_path(self.path()) {
            return Err(invalid(
                "Targets require normalized workspace-relative paths",
            ));
        }
        if let Self::JavaMethod {
            path,
            type_name,
            signature,
        } = self
        {
            if !path.ends_with(".java")
                || type_name.trim().is_empty()
                || signature.trim().is_empty()
                || signature != signature.trim()
            {
                return Err(invalid(
                    "Java targets require a type and an exact trimmed declaration",
                ));
            }
        }
        Ok(())
    }
}

/// Who implements a step; the human always owns acceptance.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(super) enum Owner {
    Human,
    Ai,
}

/// A serial step with its own scope and observable acceptance criteria.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Step {
    pub id: String,
    pub title: String,
    pub owner: Owner,
    pub targets: Vec<Target>,
    pub acceptance: Vec<String>,
    /// Unresolved questions block this step, not confirmation of the whole plan.
    pub questions: Vec<String>,
    /// Human-confirmed clarifications retained for subsequent prompts and review.
    #[serde(default)]
    pub decisions: Vec<String>,
}

/// Lifecycle state of the current step, rather than the Agent's chat activity.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(super) enum Phase {
    Draft,
    Ready,
    AiWorking,
    HumanWorking,
    Checking,
    Review,
    Complete,
}

/// Trusted host-owned snapshot. Never deserialize this directly from model output.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Plan {
    pub id: String,
    /// Monotonic state version; even pause/resume invalidates pending results.
    pub version: u64,
    pub requirement: String,
    pub steps: Vec<Step>,
    pub current_step: usize,
    pub phase: Phase,
    pub paused: bool,
}

impl Plan {
    pub(super) fn validate(&self) -> Result<(), CoreError> {
        if self.id.trim().is_empty()
            || self.requirement.trim().is_empty()
            || self.steps.is_empty()
            || self.steps.len() > 100
            || self.version == 0
            || self.current_step >= self.steps.len()
        {
            return Err(invalid(
                "Invalid collaboration plan identity, size or cursor",
            ));
        }
        let mut ids = BTreeSet::new();
        for step in &self.steps {
            if step.id.trim().is_empty()
                || !ids.insert(&step.id)
                || step.title.trim().is_empty()
                || step.acceptance.is_empty()
                || step.acceptance.iter().any(|s| s.trim().is_empty())
                || step.targets.len() > 100
                || step.questions.iter().any(|s| s.trim().is_empty())
            {
                return Err(invalid(
                    "Steps need unique IDs, a title and acceptance criteria",
                ));
            }
            let mut targets = BTreeSet::new();
            for target in &step.targets {
                target.validate()?;
                if !targets.insert(target) {
                    return Err(invalid("Duplicate step target"));
                }
            }
            for target in &step.targets {
                if matches!(target, Target::File { .. })
                    && step
                        .targets
                        .iter()
                        .any(|other| other != target && other.path() == target.path())
                {
                    return Err(invalid("Whole-file and method scopes must not overlap"));
                }
            }
        }
        let owner = self.steps[self.current_step].owner;
        if (self.phase == Phase::Complete && self.current_step + 1 != self.steps.len())
            || (self.phase == Phase::AiWorking && owner != Owner::Ai)
            || (matches!(self.phase, Phase::HumanWorking | Phase::Checking)
                && owner != Owner::Human)
        {
            return Err(invalid("Plan phase does not match its current step"));
        }
        for human in self.steps.iter().filter(|step| step.owner == Owner::Human) {
            for protected in &human.targets {
                for ai in self.steps.iter().filter(|step| step.owner == Owner::Ai) {
                    if ai.targets.iter().any(|target| {
                        target.path() == protected.path()
                            && (target == protected
                                || matches!(target, Target::File { .. })
                                || matches!(protected, Target::File { .. }))
                    }) {
                        return Err(denied("AI scope overlaps human-owned code"));
                    }
                }
            }
        }
        Ok(())
    }

    pub(super) fn check_ai(&self, version: u64, step_id: &str) -> Result<&Step, CoreError> {
        self.validate()?;
        let step = &self.steps[self.current_step];
        if self.paused
            || self.phase != Phase::AiWorking
            || version != self.version
            || step.id != step_id
        {
            return Err(denied("The confirmed AI step is no longer active"));
        }
        Ok(step)
    }
}

/// Human actions and completion notifications supplied by the host.
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum Action {
    Confirm,
    Start,
    Handoff,
    WorkFinished,
    Accept,
    RequestChanges,
    Pause,
    Resume,
    /// Only an idle step can be clarified; this is an explicit human action.
    ResolveQuestions {
        answers: Vec<String>,
    },
    /// Replaces unstarted work and requires a new confirmation.
    Revise {
        requirement: String,
        steps: Vec<Step>,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TransitionRequest {
    plan: Plan,
    expected_version: u64,
    action: Action,
}

pub(super) fn transition(request: TransitionRequest) -> Result<Plan, CoreError> {
    let mut plan = request.plan;
    plan.validate()?;
    if plan.version != request.expected_version {
        return Err(denied("Stale plan version"));
    }
    if plan.paused && !matches!(request.action, Action::Resume) {
        return Err(denied("Resume the plan before changing it"));
    }
    match request.action {
        Action::Confirm if plan.phase == Phase::Draft => plan.phase = Phase::Ready,
        Action::Start if plan.phase == Phase::Ready => {
            let step = &plan.steps[plan.current_step];
            if !step.questions.is_empty() {
                return Err(denied("Resolve this step's questions before starting"));
            }
            plan.phase = if step.owner == Owner::Ai {
                Phase::AiWorking
            } else {
                Phase::HumanWorking
            };
        }
        Action::Handoff if plan.phase == Phase::HumanWorking => plan.phase = Phase::Checking,
        Action::WorkFinished if matches!(plan.phase, Phase::AiWorking | Phase::Checking) => {
            plan.phase = Phase::Review
        }
        Action::Accept if plan.phase == Phase::Review => {
            if plan.current_step + 1 == plan.steps.len() {
                plan.phase = Phase::Complete;
            } else {
                plan.current_step += 1;
                plan.phase = Phase::Ready;
            }
        }
        Action::RequestChanges if plan.phase == Phase::Review => {
            plan.phase = if plan.steps[plan.current_step].owner == Owner::Human {
                Phase::HumanWorking
            } else {
                Phase::Ready
            };
        }
        Action::ResolveQuestions { answers } if plan.phase == Phase::Ready => {
            let step = &mut plan.steps[plan.current_step];
            if answers.len() != step.questions.len()
                || answers.iter().any(|answer| answer.trim().is_empty())
            {
                return Err(invalid(
                    "Every pending question needs a nonempty human answer",
                ));
            }
            step.decisions.extend(
                step.questions
                    .iter()
                    .zip(answers)
                    .map(|(question, answer)| format!("{question}\n{answer}")),
            );
            step.questions.clear();
        }
        Action::Pause if plan.phase != Phase::Complete => plan.paused = true,
        Action::Resume if plan.paused => {
            plan.paused = false;
            // A process may have been killed or a write interrupted. Never restart
            // automatically or claim that partial work completed successfully.
            if plan.phase == Phase::AiWorking {
                plan.phase = Phase::Ready;
            } else if plan.phase == Phase::Checking {
                plan.phase = Phase::HumanWorking;
            }
        }
        Action::Revise { requirement, steps }
            if matches!(plan.phase, Phase::Draft | Phase::Ready | Phase::Review) =>
        {
            plan.requirement = requirement;
            plan.steps.truncate(plan.current_step);
            plan.steps.extend(steps);
            plan.phase = Phase::Draft;
        }
        _ => {
            return Err(denied(
                "This action is not allowed in the current plan phase",
            ))
        }
    }
    plan.version = plan
        .version
        .checked_add(1)
        .ok_or_else(|| invalid("Plan version exhausted"))?;
    plan.validate()?;
    Ok(plan)
}
