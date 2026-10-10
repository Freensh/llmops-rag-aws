// A promptfoo provider that asks the deployed API a question as a real signed-in user.
//
// The cases use four different people, and access control is exactly what they test, so each
// question is asked with that person's own token. Tokens come from Cognito through the CI app
// client, which allows password sign-in (the web client does not).
//
// Environment: API_ENDPOINT, COGNITO_CI_CLIENT_ID, DEMO_PASSWORD, AWS_REGION.
// COGNITO_ENDPOINT overrides the Cognito address (the tests point it at a fake).

const REGION = process.env.AWS_REGION || "us-east-1";
const COGNITO_URL = process.env.COGNITO_ENDPOINT || `https://cognito-idp.${REGION}.amazonaws.com/`;

const tokens = new Map();

function signIn(email) {
  if (!tokens.has(email)) {
    const attempt = (async () => {
      const response = await fetch(COGNITO_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-amz-json-1.1",
          "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth",
        },
        body: JSON.stringify({
          AuthFlow: "USER_PASSWORD_AUTH",
          ClientId: process.env.COGNITO_CI_CLIENT_ID,
          AuthParameters: { USERNAME: email, PASSWORD: process.env.DEMO_PASSWORD },
        }),
      });
      const body = await response.json().catch(() => ({}));
      if (!body.AuthenticationResult) {
        throw new Error(`sign-in failed for ${email}: ${body.message || response.status}`);
      }
      return body.AuthenticationResult.IdToken;
    })();
    attempt.catch(() => tokens.delete(email));
    tokens.set(email, attempt);
  }
  return tokens.get(email);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Aurora and OpenSearch scale down when idle. A first question can time out at the API's
// 29 second limit, so server errors are retried.
async function ask(email, question) {
  const idToken = await signIn(email);
  let last = "";
  for (let attempt = 1; attempt <= 4; attempt++) {
    try {
      const response = await fetch(`${process.env.API_ENDPOINT}/api/chat`, {
        method: "POST",
        headers: { Authorization: `Bearer ${idToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ question }),
        signal: AbortSignal.timeout(60000),
      });
      if (response.ok) return await response.json();
      last = `HTTP ${response.status}`;
      if (response.status < 500) break; // a 4xx will not get better by asking again
    } catch (error) {
      last = String(error.message || error);
    }
    await sleep(Number(process.env.RETRY_WAIT_MS ?? 10000));
  }
  throw new Error(`the API did not answer: ${last}`);
}

export default class NorthwindProvider {
  constructor(options) {
    this.providerId = options?.id || "northwind-api";
  }

  id() {
    return this.providerId;
  }

  async callApi(_prompt, context) {
    const { email, question } = context.vars;
    try {
      const reply = await ask(email, question);
      return { output: JSON.stringify({ answer: reply.answer, sources: reply.sources || [] }) };
    } catch (error) {
      return { error: String(error.message || error) };
    }
  }
}
