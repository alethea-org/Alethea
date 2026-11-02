import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const workflowPath = path.resolve(__dirname, "../../.github/workflows/triage.yml");

export function extractSoftCheckScript(workflowContent) {
  const stepMarker = "Comment on PR if author != assignee of referenced issue";
  const stepIndex = workflowContent.indexOf(stepMarker);
  if (stepIndex === -1) {
    throw new Error(`Step "${stepMarker}" not found in workflow file`);
  }

  const scriptMarker = "script: |";
  const scriptIndex = workflowContent.indexOf(scriptMarker, stepIndex);
  if (scriptIndex === -1) {
    throw new Error(`"script: |" not found following step "${stepMarker}"`);
  }

  const lines = workflowContent.slice(scriptIndex + scriptMarker.length).split("\n");
  const scriptLines = [];
  let baseIndent = null;

  for (const line of lines) {
    if (baseIndent === null) {
      if (line.trim() === "") continue;
      const match = line.match(/^(\s+)/);
      if (!match) break;
      baseIndent = match[1].length;
    }

    if (line.trim() === "") {
      scriptLines.push("");
      continue;
    }

    const currentIndent = line.match(/^(\s*)/)[1].length;
    if (currentIndent < baseIndent) {
      break;
    }

    scriptLines.push(line.slice(baseIndent));
  }

  if (scriptLines.length === 0) {
    throw new Error(`Extracted script for "${stepMarker}" is empty`);
  }

  return scriptLines.join("\n");
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function createMockEnvironment({
  prNumber = 10,
  author = "author_user",
  body = "Closes #42",
  issues = {},
  rotaContent = "current_po: @default_po",
} = {}) {
  const comments = [];
  const warnings = [];

  const github = {
    rest: {
      issues: {
        get: async ({ owner, repo, issue_number }) => {
          if (issues[issue_number]) {
            return { data: issues[issue_number] };
          }
          throw new Error(`Issue #${issue_number} not found`);
        },
        createComment: async ({ owner, repo, issue_number, body }) => {
          comments.push({ owner, repo, issue_number, body });
          return { data: { id: comments.length } };
        },
      },
    },
  };

  const context = {
    repo: { owner: "alethea-org", repo: "Alethea" },
    payload: {
      pull_request: {
        number: prNumber,
        user: { login: author },
        body,
      },
    },
  };

  const core = {
    warning: (msg) => {
      warnings.push(msg);
    },
  };

  return { github, context, core, comments, warnings, rotaContent };
}

async function runSoftCheck(script, env) {
  const originalRota = process.env.ROTA_CONTENT;
  if (env.rotaContent !== undefined) {
    process.env.ROTA_CONTENT = env.rotaContent;
  } else {
    delete process.env.ROTA_CONTENT;
  }

  try {
    const fn = new AsyncFunction("github", "context", "core", script);
    return await fn(env.github, env.context, env.core);
  } finally {
    if (originalRota !== undefined) {
      process.env.ROTA_CONTENT = originalRota;
    } else {
      delete process.env.ROTA_CONTENT;
    }
  }
}

test("soft-check script compiles as an AsyncFunction without syntax errors", () => {
  const workflowContent = fs.readFileSync(workflowPath, "utf8");
  const script = extractSoftCheckScript(workflowContent);
  new AsyncFunction("github", "context", "core", script);
});

test("foreign-assignee: creates audit comment when author != assignee of referenced issue", async () => {
  const workflowContent = fs.readFileSync(workflowPath, "utf8");
  const script = extractSoftCheckScript(workflowContent);

  const env = createMockEnvironment({
    prNumber: 99,
    author: "bob",
    body: "Resolves #42 and fixes this",
    issues: {
      42: { assignees: [{ login: "alice" }] },
    },
    rotaContent: "current_po: @charlie_po",
  });

  await runSoftCheck(script, env);

  assert.equal(env.comments.length, 1);
  assert.equal(env.comments[0].issue_number, 99);
  assert.ok(env.comments[0].body.includes("Esta PR cierra #42"));
  assert.ok(env.comments[0].body.includes("(asignada a @alice)"));
  assert.ok(env.comments[0].body.includes("pero el autor es @bob"));
  assert.equal(env.warnings.length, 0);
});

test("same-owner: does NOT create comment when author == assignee of referenced issue", async () => {
  const workflowContent = fs.readFileSync(workflowPath, "utf8");
  const script = extractSoftCheckScript(workflowContent);

  const env = createMockEnvironment({
    prNumber: 99,
    author: "alice",
    body: "Closes #42",
    issues: {
      42: { assignees: [{ login: "alice" }] },
    },
    rotaContent: "current_po: @charlie_po",
  });

  await runSoftCheck(script, env);

  assert.equal(env.comments.length, 0);
  assert.equal(env.warnings.length, 0);
});

test("PO exception: does NOT create comment when assignee is the current PO from ROTA_CONTENT", async () => {
  const workflowContent = fs.readFileSync(workflowPath, "utf8");
  const script = extractSoftCheckScript(workflowContent);

  const env = createMockEnvironment({
    prNumber: 99,
    author: "bob",
    body: "Fixes #42",
    issues: {
      42: { assignees: [{ login: "charlie_po" }] },
    },
    rotaContent: "current_po: @charlie_po",
  });

  await runSoftCheck(script, env);

  assert.equal(env.comments.length, 0);
  assert.equal(env.warnings.length, 0);
});

test("unassigned issue: does NOT create comment when issue has no assignees", async () => {
  const workflowContent = fs.readFileSync(workflowPath, "utf8");
  const script = extractSoftCheckScript(workflowContent);

  const env = createMockEnvironment({
    prNumber: 99,
    author: "bob",
    body: "Closes #42",
    issues: {
      42: { assignees: [] },
    },
    rotaContent: "current_po: @charlie_po",
  });

  await runSoftCheck(script, env);

  assert.equal(env.comments.length, 0);
  assert.equal(env.warnings.length, 0);
});

test("no referenced issue: exits early with zero comments and zero warnings", async () => {
  const workflowContent = fs.readFileSync(workflowPath, "utf8");
  const script = extractSoftCheckScript(workflowContent);

  const env = createMockEnvironment({
    prNumber: 99,
    author: "bob",
    body: "Refactor internal helpers without closing any issues",
    issues: {},
    rotaContent: "current_po: @charlie_po",
  });

  await runSoftCheck(script, env);

  assert.equal(env.comments.length, 0);
  assert.equal(env.warnings.length, 0);
});

test("API warning: logs warning via core.warning when issue lookup fails", async () => {
  const workflowContent = fs.readFileSync(workflowPath, "utf8");
  const script = extractSoftCheckScript(workflowContent);

  const env = createMockEnvironment({
    prNumber: 99,
    author: "bob",
    body: "Closes #404",
    issues: {}, // 404 will throw
    rotaContent: "current_po: @charlie_po",
  });

  await runSoftCheck(script, env);

  assert.equal(env.comments.length, 0);
  assert.equal(env.warnings.length, 1);
  assert.ok(env.warnings[0].includes("No se pudo chequear #404"));
});
