// The same rules as check() in lambda/app/evaluate_handler.py, so the two runners agree.
//
//   must_include      every fact must appear in the answer
//   must_not_include  none of these may appear
//   source            the answer must cite this document

const normalize = (text) =>
  text.toLowerCase().replaceAll(",", "").replaceAll("$", "").replaceAll("*", "");

export default function check(output, context) {
  let reply;
  try {
    reply = JSON.parse(output);
  } catch {
    return { pass: false, score: 0, reason: "the provider returned no answer" };
  }

  const vars = context.vars;
  const mustInclude = JSON.parse(vars.must_include || "[]");
  const mustNotInclude = JSON.parse(vars.must_not_include || "[]");
  const text = normalize(reply.answer || "");

  const problems = [];
  for (const fact of mustInclude) {
    if (!text.includes(normalize(fact))) problems.push(`missing '${fact}'`);
  }
  for (const fact of mustNotInclude) {
    if (text.includes(normalize(fact))) problems.push(`leaked '${fact}'`);
  }
  if (vars.source) {
    // The API names a source "Title, Section"; the case names only the title
    const cited = (reply.sources || []).some(
      (name) => name === vars.source || name.startsWith(`${vars.source}, `),
    );
    if (!cited) problems.push(`didn't use '${vars.source}'`);
  }

  return {
    pass: problems.length === 0,
    score: problems.length === 0 ? 1 : 0,
    reason: problems.length === 0 ? "ok" : problems.join("; "),
  };
}
