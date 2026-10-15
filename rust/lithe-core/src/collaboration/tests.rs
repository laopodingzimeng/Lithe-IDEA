//! Observable contract tests for human ownership, stale work and scoped inversion.

use serde_json::{json, Value};

const SOURCE: &str =
    "class Order {\n  int core() { return 1; }\n  String map(int n) { return \"旧\"; }\n}\n";

fn run(command: &str, payload: Value) -> Value {
    serde_json::from_str(&crate::execute_json(
        &json!({
            "id": "collaboration-test", "command": command, "payload": payload
        })
        .to_string(),
    ))
    .unwrap()
}

fn target() -> Value {
    json!({"kind":"javaMethod", "path":"src/Order.java", "typeName":"Order", "signature":"String map(int n)"})
}

fn plan() -> Value {
    json!({
        "id":"order-feature", "version":1, "requirement":"Add order mapping", "currentStep":0,
        "phase":"draft", "paused":false,
        "steps":[
            {"id":"mapping", "title":"Prepare mapping", "owner":"ai", "targets":[target()],
             "acceptance":["Preserve core logic"], "questions":[]},
            {"id":"logic", "title":"Write business logic", "owner":"human",
             "targets":[{"kind":"javaMethod", "path":"src/Order.java", "typeName":"Order", "signature":"int core()"}],
             "acceptance":["Correct order result"], "questions":[]}
        ]
    })
}

fn transition(plan: Value, action: Value) -> Value {
    run(
        "collaboration.transition",
        json!({"expectedVersion":plan["version"], "plan":plan, "action":action}),
    )
}

fn advance(plan: Value, action: &str) -> Value {
    let result = transition(plan, json!({"kind": action}));
    assert_eq!(result["ok"], true, "{result}");
    result["data"].clone()
}

fn running() -> Value {
    advance(advance(plan(), "confirm"), "start")
}

fn files(source: &str) -> Value {
    json!([{"path":"src/Order.java", "text":source}])
}

fn request() -> Value {
    let plan = running();
    json!({"expectedVersion":plan["version"], "plan":plan, "stepId":"mapping", "files":files(SOURCE),
        "changes":[{"target":target(), "expectedText":"{ return \"旧\"; }", "replacement":"{ return String.valueOf(n); }"}]})
}

fn prepared() -> Value {
    let result = run("collaboration.prepare", request());
    assert_eq!(result["ok"], true, "{result}");
    result["data"].clone()
}

#[test]
fn human_handoff_and_acceptance_are_required_before_advancing() {
    let mut state = running();
    assert_eq!(
        transition(state.clone(), json!({"kind":"accept"}))["ok"],
        false
    );
    state = advance(state, "workFinished");
    assert_eq!(state["currentStep"], 0);
    state = advance(state, "accept");
    state = advance(state, "start");
    assert_eq!(state["phase"], "humanWorking");
    assert_eq!(
        transition(state.clone(), json!({"kind":"workFinished"}))["ok"],
        false
    );
    state = advance(state, "handoff");
    state = advance(state, "workFinished");
    state = advance(state, "requestChanges");
    assert_eq!(state["phase"], "humanWorking");
    state = advance(state, "handoff");
    state = advance(state, "workFinished");
    state = advance(state, "accept");
    assert_eq!(state["phase"], "complete");
}

#[test]
fn questions_block_only_their_step_and_revisions_require_confirmation() {
    let mut state = plan();
    state["steps"][0]["questions"] = json!(["Which mapping convention?"]);
    state = advance(state, "confirm");
    assert_eq!(
        transition(state.clone(), json!({"kind":"start"}))["ok"],
        false
    );
    let resolved = transition(
        state,
        json!({"kind":"resolveQuestions", "answers":["Use the existing mapping conventions"]}),
    );
    assert_eq!(resolved["ok"], true, "{resolved}");
    state = resolved["data"].clone();
    assert!(state["steps"][0]["decisions"][0]
        .as_str()
        .unwrap()
        .contains("Use the existing"));
    state = advance(state, "start");
    state = advance(state, "workFinished");
    state = advance(state, "accept");
    let result = transition(
        state.clone(),
        json!({"kind":"revise", "requirement":"Revised order requirement",
        "steps":[state["steps"][1].clone()]}),
    );
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["data"]["currentStep"], 1);
    assert_eq!(result["data"]["phase"], "draft");
    assert_eq!(result["data"]["steps"][0], state["steps"][0]);
}

#[test]
fn pause_invalidates_work_and_resume_never_auto_accepts_interrupted_work() {
    let mut request = request();
    let state = advance(request["plan"].clone(), "pause");
    request["plan"] = state.clone();
    assert_eq!(run("collaboration.prepare", request.clone())["ok"], false);
    let state = advance(state, "resume");
    assert_eq!(state["phase"], "ready");
    let state = advance(state, "start");
    request["plan"] = state;
    assert_eq!(run("collaboration.prepare", request)["ok"], false);
}

#[test]
fn scoped_edit_preserves_core_logic_and_unicode_exactly() {
    let result = prepared();
    assert_eq!(result["before"], files(SOURCE));
    assert_eq!(
        result["after"],
        files(&SOURCE.replace("{ return \"旧\"; }", "{ return String.valueOf(n); }"))
    );
}

#[test]
fn inverse_preserves_subsequent_human_changes_in_other_methods() {
    let receipt = prepared();
    let current = receipt["after"][0]["text"]
        .as_str()
        .unwrap()
        .replace("return 1", "return 42");
    let result = run(
        "collaboration.reverse",
        json!({"receipt":receipt,"files":files(&current)}),
    );
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(
        result["data"]["after"],
        files(&SOURCE.replace("return 1", "return 42"))
    );
}

#[test]
fn inverse_refuses_human_edits_inside_the_ai_method() {
    let receipt = prepared();
    let current = receipt["after"][0]["text"]
        .as_str()
        .unwrap()
        .replace("String.valueOf(n)", "\"human\"");
    let result = run(
        "collaboration.reverse",
        json!({"receipt":receipt,"files":files(&current)}),
    );
    assert_eq!(result["ok"], false);
    assert_eq!(result["error"]["code"], "permission_denied");
}

#[test]
fn stale_sources_wrong_step_and_human_phase_cannot_apply() {
    let mut stale = request();
    stale["files"] = files(&SOURCE.replace("\"旧\"", "\"edited\""));
    assert_eq!(run("collaboration.prepare", stale)["ok"], false);
    let mut wrong_step = request();
    wrong_step["stepId"] = json!("logic");
    assert_eq!(run("collaboration.prepare", wrong_step)["ok"], false);
    let mut human = request();
    human["plan"] = advance(
        advance(advance(human["plan"].clone(), "workFinished"), "accept"),
        "start",
    );
    human["expectedVersion"] = human["plan"]["version"].clone();
    human["stepId"] = json!("logic");
    assert_eq!(run("collaboration.prepare", human)["ok"], false);
}

#[test]
fn file_grants_cannot_override_a_human_method_and_payload_cannot_expand_scope() {
    let mut state = plan();
    state["steps"][0]["targets"] = json!([{"kind":"file","path":"src/Order.java"}]);
    assert_eq!(transition(state, json!({"kind":"confirm"}))["ok"], false);
    let mut request = request();
    request["changes"][0]["target"] = json!({"kind":"file","path":"src/Order.java"});
    assert_eq!(run("collaboration.prepare", request)["ok"], false);
}

#[test]
fn braces_cannot_escape_the_authorized_method_body() {
    let mut request = request();
    request["changes"][0]["replacement"] = json!("{ return \"x\"; } int injected() { return 9; }");
    assert_eq!(run("collaboration.prepare", request)["ok"], false);
}

#[test]
fn overloads_and_nested_types_are_not_confused() {
    let mut request = request();
    let source = "class Order { int core() { return 1; } String map(String n) { return n; } String map(int n) { return \"旧\"; } class Inner { String map(int n) { return \"inner\"; } } }";
    request["files"] = files(source);
    let result = run("collaboration.prepare", request);
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(
        result["data"]["after"],
        files(&source.replace("{ return \"旧\"; }", "{ return String.valueOf(n); }"))
    );
}

#[test]
fn malformed_or_changed_java_declarations_fail_closed() {
    for source in [
        SOURCE.replace("String map(int n)", "String map(long n)"),
        format!("{SOURCE} class Broken {{"),
    ] {
        let mut request = request();
        request["files"] = files(&source);
        assert_eq!(run("collaboration.prepare", request)["ok"], false);
    }
}

#[test]
fn new_file_inverse_refuses_to_delete_subsequent_user_edits() {
    let mut request = request();
    let target = json!({"kind":"file", "path":"src/Dto.java"});
    request["plan"]["steps"][0]["targets"] = json!([target.clone()]);
    request["changes"] =
        json!([{"target":target, "expectedText":null,"replacement":"class Dto {}"}]);
    request["files"] = json!([{"path":"src/Dto.java","text":null}]);
    let result = run("collaboration.prepare", request);
    assert_eq!(result["ok"], true, "{result}");
    let receipt = result["data"].clone();
    let reverted = run(
        "collaboration.reverse",
        json!({"receipt":receipt,"files":receipt["after"]}),
    );
    assert_eq!(reverted["ok"], true, "{reverted}");
    assert_eq!(reverted["data"]["after"][0]["text"], Value::Null);
    let changed = run(
        "collaboration.reverse",
        json!({"receipt":receipt,"files":[{"path":"src/Dto.java","text":"class Dto { int human; }"}]}),
    );
    assert_eq!(changed["ok"], false);
}

#[test]
fn unsafe_paths_duplicate_targets_and_corrupt_receipts_are_rejected() {
    for path in [
        "../escape",
        "/absolute",
        "a/../b",
        "a\\b",
        ".git/config",
        "a//b",
        "C:/src",
    ] {
        let mut state = plan();
        state["steps"][0]["targets"] = json!([{"kind":"file","path":path}]);
        assert_eq!(
            transition(state, json!({"kind":"confirm"}))["ok"],
            false,
            "{path}"
        );
    }
    let mut duplicate = request();
    duplicate["changes"] = json!([
        duplicate["changes"][0].clone(),
        duplicate["changes"][0].clone()
    ]);
    assert_eq!(run("collaboration.prepare", duplicate)["ok"], false);
    let mut receipt = prepared();
    receipt["after"][0]["text"] = json!("corrupt");
    assert_eq!(
        run(
            "collaboration.reverse",
            json!({"files":receipt["after"],"receipt":receipt})
        )["ok"],
        false
    );
}

#[test]
fn multi_file_failure_returns_no_partial_changes() {
    let mut request = request();
    let target = json!({"kind":"file","path":"src/Dto.java"});
    request["plan"]["steps"][0]["targets"]
        .as_array_mut()
        .unwrap()
        .push(target.clone());
    request["changes"]
        .as_array_mut()
        .unwrap()
        .push(json!({"target":target,"expectedText":null,"replacement":"class Dto {}"}));
    // Missing the second snapshot must fail the entire pure preparation.
    let result = run("collaboration.prepare", request);
    assert_eq!(result["ok"], false);
    assert!(result.get("data").is_none() || result["data"].is_null());
}

#[test]
fn shared_fixture_keeps_the_core_envelope_and_question_gate_stable() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/agent/collaboration-v1.json"
    ))
    .unwrap();
    let response: Value =
        serde_json::from_str(&crate::execute_json(&fixture["request"].to_string())).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    for (key, expected) in fixture["expected"].as_object().unwrap() {
        assert_eq!(&response["data"][key], expected, "{key}");
    }
    assert_eq!(
        transition(response["data"].clone(), json!({"kind":"start"}))["ok"],
        false
    );
}

#[test]
fn outer_ai_method_cannot_contain_a_human_owned_local_class_method() {
    let source = "class Order { void outer() { class Inner { int core() { return 1; } } } }";
    let outer = json!({"kind":"javaMethod","path":"src/Order.java","typeName":"Order","signature":"void outer()"});
    let inner = json!({"kind":"javaMethod","path":"src/Order.java","typeName":"Order.Inner","signature":"int core()"});
    let mut request = request();
    request["plan"]["steps"][0]["targets"] = json!([outer.clone()]);
    request["plan"]["steps"][1]["targets"] = json!([inner]);
    request["files"] = files(source);
    request["changes"] = json!([{"target":outer,"expectedText":"{ class Inner { int core() { return 1; } } }","replacement":"{}"}]);
    assert_eq!(run("collaboration.prepare", request)["ok"], false);
}

#[test]
fn stale_transition_and_empty_answers_do_not_advance_state() {
    let response = run(
        "collaboration.transition",
        json!({"plan":plan(),"expectedVersion":0,"action":{"kind":"confirm"}}),
    );
    assert_eq!(response["ok"], false);
    let mut state = plan();
    state["steps"][0]["questions"] = json!(["Which rule?"]);
    state = advance(state, "confirm");
    assert_eq!(
        transition(
            state.clone(),
            json!({"kind":"resolveQuestions","answers":[]})
        )["ok"],
        false
    );
    assert_eq!(
        transition(state, json!({"kind":"resolveQuestions","answers":[" "]}))["ok"],
        false
    );
}

#[test]
fn whole_file_transaction_is_sorted_and_preserves_empty_vs_absent() {
    let mut request = request();
    let z = json!({"kind":"file","path":"z.txt"});
    let a = json!({"kind":"file","path":"a.txt"});
    request["plan"]["steps"][0]["targets"] = json!([z.clone(), a.clone()]);
    request["files"] = json!([{"path":"z.txt","text":""},{"path":"a.txt","text":null}]);
    request["changes"] = json!([
        {"target":z,"expectedText":"","replacement":"z"},
        {"target":a,"expectedText":null,"replacement":""}
    ]);
    let result = run("collaboration.prepare", request);
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(
        result["data"]["after"][0],
        json!({"path":"a.txt","text":""})
    );
    assert_eq!(
        result["data"]["after"][1],
        json!({"path":"z.txt","text":"z"})
    );
    let reversed = run(
        "collaboration.reverse",
        json!({"receipt":result["data"],"files":result["data"]["after"]}),
    );
    assert_eq!(reversed["ok"], true, "{reversed}");
    assert_eq!(reversed["data"]["after"][0]["text"], Value::Null);
    assert_eq!(reversed["data"]["after"][1]["text"], "");
}

#[test]
fn oversized_sources_are_rejected_before_java_parsing() {
    let mut request = request();
    request["files"] = files(&" ".repeat(2 * 1024 * 1024 + 1));
    assert_eq!(
        run("collaboration.prepare", request)["error"]["code"],
        "invalid_request"
    );
}

#[test]
fn native_workflow_packages_preserve_handoff_contract() {
    // The native data packages must survive the same confirmed handoffs as the
    // product, including unresolved questions and explicit human acceptance.
    for source in [
        include_str!("../../../../shared/fixtures/collaboration/spring-order.workflow.json"),
        include_str!("../../../../shared/fixtures/collaboration/maintenance-review.workflow.json"),
    ] {
        let package: Value = serde_json::from_str(source).unwrap();
        let mut current = json!({
            "id":"native-fixture", "version":1, "requirement":package["requirement"],
            "steps":package["steps"], "currentStep":0, "phase":"draft", "paused":false
        });
        current = advance(current, "confirm");
        for step in package["steps"].as_array().unwrap() {
            let questions = step["questions"].as_array().unwrap();
            if !questions.is_empty() {
                let answers: Vec<&str> = questions.iter().map(|_| "Human-confirmed rule").collect();
                let resolved = transition(
                    current,
                    json!({"kind":"resolveQuestions", "answers":answers}),
                );
                assert_eq!(resolved["ok"], true, "{resolved}");
                current = resolved["data"].clone();
            }
            current = advance(current, "start");
            if step["owner"] == "human" {
                current = advance(current, "handoff");
            }
            current = advance(current, "workFinished");
            assert_eq!(current["phase"], "review");
            current = advance(current, "accept");
        }
        assert_eq!(current["phase"], "complete");
    }
}
