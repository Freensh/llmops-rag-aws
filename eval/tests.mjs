// Turns lambda/data/evaluation_questions.json into promptfoo tests, so there is one list of
// cases and the two runners cannot drift apart.
//
// The gate sets ONLY_KEYS_JSON to re-run just the cases that failed the first time.

import { caseKey, hasHistory, isCritical, loadCases } from "./keys.mjs";

const only = process.env.ONLY_KEYS_JSON ? new Set(JSON.parse(process.env.ONLY_KEYS_JSON)) : null;

export default loadCases()
  .filter((testCase) => !hasHistory(testCase))
  .filter((testCase) => !only || only.has(caseKey(testCase)))
  .map((testCase) => ({
    description: caseKey(testCase),
    vars: {
      key: caseKey(testCase),
      email: testCase.email,
      question: testCase.question,
      // JSON text, because a list in a promptfoo variable would multiply the test
      must_include: JSON.stringify(testCase.must_include || []),
      must_not_include: JSON.stringify(testCase.must_not_include || []),
      source: testCase.source || "",
    },
    metadata: { critical: isCritical(testCase) },
  }));
