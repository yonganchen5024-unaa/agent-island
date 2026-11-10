// Agent Island adapter for OpenCode (written against 1.18.31). Install with agent-island-watch.py beside it.
//
// OpenCode's `permission.ask` plugin hook is never called in this version, so approvals use the
// `permission.asked` / `question.asked` events and the same reply API the TUI uses. Requests are
// answered by the first reply; there is no waiting for other plugins.
//
// Safety contract: the only thing that can produce a reply is an explicit decision printed by the
// authenticated claude_approval_hook.py. Every other outcome (crash, timeout, bad output, broker
// gone, an exception here) sends nothing, and OpenCode's own prompt stays in control.
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HOOK = process.env.AGENT_ISLAND_HOOK || join(homedir(), "Library/Application Support/Agent Island/bin/claude_approval_hook.py");
const RUNTIME = process.env.AGENT_ISLAND_RUNTIME || `/private/tmp/cc-socks/agent-island-${process.getuid()}-approval`;
const PYTHON = process.env.AGENT_ISLAND_PYTHON || "/usr/bin/python3";
const WATCH = join(dirname(fileURLToPath(import.meta.url)), "agent-island-watch.py");
const WAIT_SECONDS = "3590";
const MAX_REMEMBERED = 512;
const TOOL_NAMES = {
  bash: "Bash", edit: "Edit", write: "Write", read: "Read", glob: "Glob", grep: "Grep", webfetch: "WebFetch",
  todowrite: "TodoWrite", task: "Task", skill: "Skill", apply_patch: "Edit", question: "AskUserQuestion",
};
// Tools that ask under a permission name other than their own, and that name.
const EDITS = new Set(["edit", "write", "apply_patch"]);

function runHook(payload) {
  const child = spawn(PYTHON, ["-I", HOOK, "--runtime", RUNTIME, "--source", "opencode", "--timeout", WAIT_SECONDS],
    { stdio: ["pipe", "pipe", "ignore"] });
  const chunks = [];
  const done = new Promise((resolve) => {
    child.on("error", () => resolve(null));
    child.on("close", (code) => resolve(code === 0 ? Buffer.concat(chunks).toString("utf8") : null));
  });
  child.stdout.on("data", (chunk) => chunks.push(chunk));
  child.stdin.on("error", () => {});
  child.stdin.end(JSON.stringify(payload));
  return { child, done };
}

// Returns {behavior, message?, updatedInput?} only for a well-formed hook decision.
function parseDecision(text) {
  if (!text) return null;
  let output;
  try { output = JSON.parse(text); } catch { return null; }
  const specific = output?.hookSpecificOutput;
  if (specific?.hookEventName !== "PermissionRequest") return null;
  const decision = specific.decision;
  return decision?.behavior === "allow" || decision?.behavior === "deny" ? decision : null;
}

function questionInput(questions) {
  return {
    questions: (questions || []).map((q) => ({
      question: q.question, header: q.header, options: q.options, multiSelect: q.multiple === true,
    })),
  };
}

// The island shows file_path and command specially; every original field is kept.
function toolInput(tool, args) {
  if (tool === "question") return questionInput(args?.questions);
  const input = { ...(args || {}) };
  if (typeof input.filePath === "string") input.file_path = input.filePath;
  return input;
}

// OpenCode wants one array of labels per question; the island sends joined text for multi-select.
function answersFor(questions, answers) {
  return questions.map((q) => {
    const value = answers?.[q.question];
    if (typeof value !== "string") return null;
    const labels = (q.options || []).map((o) => o.label);
    if (labels.includes(value) || !q.multiple) return [value];
    const parts = value.split(", ");
    return parts.every((part) => labels.includes(part)) ? parts : [value];
  });
}

function remember(map, key, value) {
  map.set(key, value);
  if (map.size > MAX_REMEMBERED) map.delete(map.keys().next().value);
}

export const AgentIslandAdapter = async ({ client, directory }) => {
  const sessions = new Map(); // id -> { parent, directory, busy, failed }
  const calls = new Map();    // callID -> { tool, args }
  const finished = new Map(); // callID -> true: a call reports its end once
  const pending = new Map();  // request id -> { run, session }

  let watcher;
  try {
    watcher = spawn(PYTHON, ["-I", WATCH, "--python", PYTHON, "--hook", HOOK, "--runtime", RUNTIME],
      { stdio: ["pipe", "ignore", "ignore"], detached: true });
    watcher.on("error", () => { watcher = undefined; });
    watcher.stdin.on("error", () => { watcher = undefined; });
    watcher.unref();
    watcher.stdin.unref?.();
  } catch { watcher = undefined; }

  function session(id) {
    let value = sessions.get(id);
    if (!value) remember(sessions, id, value = {});
    return value;
  }

  function rootOf(id) {
    let current = id;
    for (let depth = 0; depth < 16; depth++) {
      const parent = sessions.get(current)?.parent;
      if (!parent) break;
      current = parent;
    }
    return current;
  }

  function identity(id) {
    const root = rootOf(id);
    const fields = { session_id: root, cwd: sessions.get(root)?.directory || sessions.get(id)?.directory || directory };
    if (root !== id) { fields.agent_id = id; fields.agent_type = "subagent"; }
    return fields;
  }

  function send(name, id, extra) {
    if (!id) return;
    const fields = identity(id);
    if (watcher) {
      try { watcher.stdin.write(JSON.stringify({ add: fields.session_id, cwd: fields.cwd }) + "\n"); } catch {}
    }
    try { runHook({ hook_event_name: name, ...fields, ...extra }).done.catch(() => {}); } catch {}
  }

  function endSession(id) {
    if (watcher) {
      try { watcher.stdin.write(JSON.stringify({ del: id }) + "\n"); } catch {}
    }
    send("SessionEnd", id);
    sessions.delete(id);
  }

  function cancelSession(id) {
    for (const [requestID, entry] of pending) if (entry.session === id) cancel(requestID);
  }

  // Ends the hook; its socket closing is what withdraws the island card.
  function cancel(requestID) {
    const entry = pending.get(requestID);
    if (!entry) return;
    pending.delete(requestID);
    try { entry.run.child.kill("SIGTERM"); } catch {}
  }

  async function post(path, body) {
    await client._client.post({ url: path, body, headers: { "Content-Type": "application/json" } });
  }

  // Waits for the island and replies only on an explicit decision. Replying twice is harmless:
  // OpenCode answers the second with 404 and keeps the first.
  async function askIsland(request, toolName, input, reply) {
    if (pending.has(request.id)) return;
    const run = runHook({ hook_event_name: "PermissionRequest", ...identity(request.sessionID), tool_name: toolName, tool_input: input });
    const entry = { run, session: request.sessionID };
    pending.set(request.id, entry);
    const text = await run.done;
    if (pending.get(request.id) !== entry) return; // Answered elsewhere; the hook was cancelled.
    pending.delete(request.id);
    const decision = parseDecision(text);
    if (decision) await reply(decision);
  }

  function onPermissionAsked(request) {
    const call = request.tool?.callID ? calls.get(request.tool.callID) : undefined;
    const ownAsk = call && (call.tool === request.permission || (request.permission === "edit" && EDITS.has(call.tool)));
    let toolName, input;
    if (ownAsk) {
      toolName = TOOL_NAMES[call.tool] || call.tool;
      input = toolInput(call.tool, call.args);
    } else {
      // external_directory, doom_loop and the like are separate questions about the call.
      toolName = request.permission;
      input = { permission: request.permission, patterns: request.patterns, metadata: request.metadata };
      if (call) input.tool = { name: call.tool, args: call.args };
    }
    return askIsland(request, toolName, input, async (decision) => {
      const body = decision.behavior === "allow" ? { reply: "once" } : { reply: "reject", message: decision.message };
      await post(`/permission/${encodeURIComponent(request.id)}/reply`, body);
    });
  }

  function onQuestionAsked(request) {
    return askIsland(request, "AskUserQuestion", questionInput(request.questions), async (decision) => {
      const id = encodeURIComponent(request.id);
      if (decision.behavior === "deny") return post(`/question/${id}/reject`, {});
      const answers = answersFor(request.questions, decision.updatedInput?.answers);
      if (answers.some((answer) => answer === null)) return;
      await post(`/question/${id}/reply`, { answers });
    });
  }

  function onToolEnded(sessionID, callID, tool, args, failed) {
    if (callID) {
      if (finished.has(callID)) return;
      remember(finished, callID, true);
      calls.delete(callID);
    }
    send(failed ? "PostToolUseFailure" : "PostToolUse", sessionID, {
      tool_name: TOOL_NAMES[tool] || tool, tool_input: toolInput(tool, args), tool_use_id: callID,
    });
  }

  function onSessionInfo(info, started) {
    if (!info?.id) return;
    const value = session(info.id);
    if (info.parentID) value.parent = info.parentID;
    if (info.directory) value.directory = info.directory;
    if (!started) return;
    if (info.parentID) send("SubagentStart", info.id);
    else send("SessionStart", info.id);
  }

  function onStatus(id, type) {
    if (!id) return;
    const value = session(id);
    if (type === "busy") { value.busy = true; value.failed = false; return; }
    if (type !== "idle") return;
    cancelSession(id);
    if (!value.busy) return;
    value.busy = false;
    if (value.parent) send("SubagentStop", id);
    else if (!value.failed) send("Stop", id);
  }

  function handle(event) {
    const properties = event?.properties || {};
    switch (event?.type) {
      case "session.created": return onSessionInfo(properties.info, true);
      case "session.updated": return onSessionInfo(properties.info, false);
      case "session.deleted":
        if (properties.info?.id) { cancelSession(properties.info.id); endSession(properties.info.id); }
        return;
      case "session.status": return onStatus(properties.sessionID, properties.status?.type);
      case "session.error":
        // An abort is the user's doing, not a failure; the idle that follows reports it as a stop.
        if (properties.sessionID && properties.error?.name !== "MessageAbortedError") {
          session(properties.sessionID).failed = true;
          send("StopFailure", properties.sessionID);
        }
        return;
      case "message.part.updated": {
        const part = properties.part;
        if (part?.type === "tool" && part.state?.status === "error") onToolEnded(part.sessionID, part.callID, part.tool, part.state.input, true);
        return;
      }
      case "permission.asked": return void onPermissionAsked(properties).catch(() => {});
      case "question.asked": return void onQuestionAsked(properties).catch(() => {});
      case "permission.replied":
      case "question.replied":
      case "question.rejected":
        return cancel(properties.requestID);
    }
  }

  return {
    // OpenCode calls this synchronously in a loop over all plugins. It must never throw.
    event: async ({ event }) => { try { handle(event); } catch {} },
    "chat.message": async (input) => {
      try {
        const root = rootOf(input.sessionID);
        // A prompt queued behind a pending request would otherwise end that request's card.
        if (root !== input.sessionID || [...pending.values()].some((e) => rootOf(e.session) === root)) return;
        send("UserPromptSubmit", input.sessionID);
      } catch {}
    },
    "tool.execute.before": async (input, output) => {
      try {
        remember(calls, input.callID, { tool: input.tool, args: output.args });
        send("PreToolUse", input.sessionID, {
          tool_name: TOOL_NAMES[input.tool] || input.tool, tool_input: toolInput(input.tool, output.args), tool_use_id: input.callID,
        });
      } catch {}
    },
    "tool.execute.after": async (input) => {
      try { onToolEnded(input.sessionID, input.callID, input.tool, input.args, false); } catch {}
    },
    dispose: async () => {
      try {
        for (const requestID of [...pending.keys()]) cancel(requestID);
        watcher?.stdin.end();
      } catch {}
    },
  };
};
