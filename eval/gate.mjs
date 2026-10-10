// The gate: decides whether a change may ship, from the results of the evaluation.
//
//   node gate.mjs --failed out/run1.json        print the keys of failed cases, as JSON
//   node gate.mjs --run1 out/run1.json [--run2 out/run2.json] [--lambda ../build/evaluation.json]
//   node gate.mjs ... --init                    write a new baseline.json from these results
//
// Three rules, all must hold:
//   1. Critical cases never fail. A critical case is a leak check: a refusal, a prompt
//      injection or a superseded policy (any case with "must_not_include").
//   2. No regression. Every case listed in baseline.json "must_pass" still passes.
//   3. The floor. At least baseline.json "floor" cases pass in total.
//
// A case that failed the first run is asked again once (run2). It passes if either run did,
// because a model can answer differently between two identical calls.
// Cases in "known_failing" are expected to fail and do not count against rules 1 and 2.

import fs from "node:fs";
import { caseKey, hasHistory, isCritical, loadCases } from "./keys.mjs";

const args = process.argv.slice(2);
const option = (name) => {
  const at = args.indexOf(name);
  return at === -1 ? undefined : args[at + 1];
};

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf-8"));
}

// What promptfoo writes: { results: { results: [ { vars, success, ... } ] } }
// Older and newer versions nest it slightly differently, so look in both places.
function promptfooResults(file) {
  const data = readJson(file);
  const rows = data.results?.results ?? data.results ?? [];
  const found = new Map();
  for (const row of rows) {
    const key = row.vars?.key ?? row.testCase?.vars?.key;
    if (key) found.set(key, { pass: Boolean(row.success), reason: reasonOf(row) });
  }
  return found;
}

function reasonOf(row) {
  if (row.error) return String(row.error);
  return row.gradingResult?.reason || "";
}

if (option("--failed")) {
  const failed = [...promptfooResults(option("--failed"))]
    .filter(([, result]) => !result.pass)
    .map(([key]) => key);
  console.log(JSON.stringify(failed));
  process.exit(0);
}

const cases = loadCases();
const critical = new Set(cases.filter(isCritical).map(caseKey));
const byQuestion = new Map(cases.filter(hasHistory).map((c) => [c.question, caseKey(c)]));

const results = new Map(); // key -> { pass, reason, runner }

for (const [key, result] of promptfooResults(option("--run1"))) {
  results.set(key, { ...result, runner: "promptfoo" });
}
if (option("--run2") && fs.existsSync(option("--run2"))) {
  for (const [key, second] of promptfooResults(option("--run2"))) {
    const first = results.get(key);
    if (first && !first.pass && second.pass) {
      results.set(key, { pass: true, reason: "passed on the second try", runner: "promptfoo", flaky: true });
    }
  }
}

// The cases that need a conversation history run on the evaluate Lambda
if (option("--lambda") && fs.existsSync(option("--lambda"))) {
  const lambda = readJson(option("--lambda"));
  const failedQuestions = new Map((lambda.failures || []).map((f) => [f.question, f.problems.join("; ")]));
  for (const [question, key] of byQuestion) {
    const failure = failedQuestions.get(question);
    // A history case that is not among the Lambda's failures passed, provided the Lambda ran
    results.set(key, { pass: !failure, reason: failure || "", runner: "lambda" });
  }
}

const baselineFile = new URL("./baseline.json", import.meta.url);

if (args.includes("--init")) {
  const existing = fs.existsSync(baselineFile) ? readJson(baselineFile) : {};
  const passing = [...results].filter(([, r]) => r.pass).map(([k]) => k).sort();
  const known = {};
  for (const [key, result] of results) {
    if (!result.pass) known[key] = existing.known_failing?.[key] || `failed: ${result.reason}`;
  }
  const baseline = { floor: passing.length, must_pass: passing, known_failing: known };
  fs.writeFileSync(baselineFile, `${JSON.stringify(baseline, null, 2)}\n`);
  console.log(`baseline.json written: ${passing.length} must pass, ${Object.keys(known).length} known failing`);
  process.exit(0);
}

const baseline = readJson(baselineFile);
const mustPass = new Set(baseline.must_pass);
const knownFailing = new Set(Object.keys(baseline.known_failing || {}));

const problems = [];
const notes = [];

// Which keys the gate expects results for: everything in the case file
const expected = cases.map(caseKey);
const missing = expected.filter((key) => !results.has(key));
for (const key of missing) {
  if (mustPass.has(key) || critical.has(key)) problems.push(`no result for ${key} (the evaluation did not run it)`);
}

for (const [key, result] of results) {
  if (result.pass) {
    if (knownFailing.has(key)) notes.push(`now passes, remove it from known_failing: ${key}`);
    if (result.flaky) notes.push(`needed a second try: ${key}`);
    continue;
  }
  if (knownFailing.has(key)) continue;
  if (critical.has(key)) problems.push(`CRITICAL case failed: ${key} (${result.reason})`);
  else if (mustPass.has(key)) problems.push(`regression: ${key} (${result.reason})`);
  else notes.push(`new case failing, not yet in the baseline: ${key} (${result.reason})`);
}

const passed = [...results.values()].filter((r) => r.pass).length;
if (passed < baseline.floor) problems.push(`only ${passed} cases passed, the floor is ${baseline.floor}`);

// An outage can fail every case at once. Show the first few so the summary stays readable.
const MAX_SHOWN = 10;
const shown = problems.slice(0, MAX_SHOWN).map((p) => `- :x: ${p}`);
if (problems.length > MAX_SHOWN) shown.push(`- :x: ...and ${problems.length - MAX_SHOWN} more problems`);

const lines = [
  `### Evaluation gate: ${problems.length === 0 ? "passed" : "FAILED"}`,
  `${passed} of ${expected.length} cases pass (floor ${baseline.floor}).`,
  ...shown,
  ...notes.map((n) => `- :information_source: ${n}`),
];
console.log(lines.join("\n"));
if (process.env.GITHUB_STEP_SUMMARY) {
  fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${lines.join("\n")}\n`);
}
process.exit(problems.length === 0 ? 0 : 1);
