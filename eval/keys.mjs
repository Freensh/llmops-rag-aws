// One name per evaluation case, used by the tests, the gate and the baseline.
// "amara.diallo|What is my salary?" is readable in a failing check and in a pull request diff.
import fs from "node:fs";

const FILE = new URL("../lambda/data/evaluation_questions.json", import.meta.url);

export function loadCases() {
  return JSON.parse(fs.readFileSync(FILE, "utf-8"));
}

export function caseKey(testCase) {
  return `${testCase.email.split("@")[0]}|${testCase.question}`;
}

// A case that has a "must_not_include" list is a leak check: a refusal, a prompt injection or
// a superseded policy. These are the ones that must never fail.
export function isCritical(testCase) {
  return (testCase.must_not_include || []).length > 0;
}

// Cases that replay an earlier conversation. The API builds a conversation from the messages
// it stored itself, so these cannot be replayed through it. The evaluate Lambda runs them.
export function hasHistory(testCase) {
  return (testCase.history || []).length > 0;
}
