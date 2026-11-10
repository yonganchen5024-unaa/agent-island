// Agent Island adapter for DeepSeek Harness (DSH): a Cordis plugin mounted through a profile patch.
// See docs/reference/agent-dsh.md for evidence and installation.
//
// DSH has no command hooks. Everything that happens in a session passes through in-process events, and
// approvals pass through the `approval/request` waterfall. This plugin translates both into the JSON
// shape of scripts/claude_approval_hook.py and runs that script as a child process.
//
// Decision rules, which the tests in Tests/e2e/run_dsh_approval.py pin down:
//   * `allowed-once` is returned only when the hook printed a well-formed allow. An exit code, an
//     empty or malformed reply, a timeout, a missing broker or our own exception is never a grant.
//   * DSH's own answerer (`next()`) runs at the same time. Whichever side really decides first wins.
//     If the hook ends without a decision, DSH's answerer stays in charge; if DSH has no answerer
//     (headless), the result is `unavailable`, which DSH turns into a denial.
//   * Nothing here mutates tool input or answers on the island's behalf.
import { spawn } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'agent-island'

const SOURCE = 'dsh'
const LIFECYCLE_TIMEOUT_MS = 3000
const LIFECYCLE_QUEUE_LIMIT = 256
const SESSION_ID = /^[A-Za-z0-9_:-]{1,128}$/

function settings(config) {
  return {
    python: config?.python ?? '/usr/bin/python3',
    hook: config?.hook ?? join(homedir(), 'Library/Application Support/Agent Island/bin/claude_approval_hook.py'),
    runtime: config?.runtime ?? `/private/tmp/cc-socks/agent-island-${process.getuid()}-approval`,
    timeout: Number.isFinite(config?.timeoutSeconds) ? config.timeoutSeconds : 3590,
  }
}

function hookArgs(options, timeout) {
  return ['-I', options.hook, '--runtime', options.runtime, '--source', SOURCE, '--timeout', String(timeout)]
}

/** Run the hook once. Resolves with its stdout, or null if it could not be run to completion. */
function runHook(options, timeout, event, killAfterMs, register) {
  return new Promise(resolve => {
    let child
    let timer
    let done = false
    const finish = value => {
      if (done) return
      done = true
      clearTimeout(timer)
      resolve(value)
    }
    try {
      // AGENT_ISLAND_PID is unused today; it lets a future liveness check tie a row to this process.
      child = spawn(options.python, hookArgs(options, timeout), {
        stdio: ['pipe', 'pipe', 'ignore'],
        // A minimal environment: the hook needs none of DSH's, which can hold API keys.
        env: { PATH: '/usr/bin:/bin', AGENT_ISLAND_PID: String(process.pid) },
      })
    } catch {
      return finish(null)
    }
    register?.(child)
    const chunks = []
    child.stdout.on('data', chunk => chunks.push(chunk))
    child.stdout.on('error', () => {})
    child.stdin.on('error', () => {})
    child.on('error', () => finish(null))
    child.on('close', () => finish(Buffer.concat(chunks).toString('utf8')))
    if (killAfterMs !== undefined) timer = setTimeout(() => { child.kill('SIGTERM'); finish(null) }, killAfterMs)
    try { child.stdin.end(JSON.stringify(event)) } catch { finish(null) }
  })
}

/** The only path to a grant. Anything that is not exactly an allow or a deny is no decision at all. */
function decisionFrom(stdout) {
  if (typeof stdout !== 'string' || stdout.trim() === '') return null
  let parsed
  try { parsed = JSON.parse(stdout) } catch { return null }
  const output = parsed?.hookSpecificOutput
  if (output?.hookEventName !== 'PermissionRequest') return null
  const decision = output.decision
  // DSH grants are one-shot and cannot carry edited input or rules, so a reply that asks for those
  // cannot be honoured as asked, and is not treated as an allow.
  if (decision?.behavior === 'allow' && decision.updatedInput === undefined && decision.updatedPermissions === undefined) return 'allowed-once'
  if (decision?.behavior === 'deny') return 'rejected'
  return null
}

function toolInputFor(session, callId) {
  // The approval request itself carries no arguments, only the tool name and a reason.
  const events = session?.events ?? []
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event.type === 'tool/call' && event.data?.callId === callId) return parseArguments(event.data.arguments)
  }
  return null
}

function parseArguments(raw) {
  if (typeof raw !== 'string') return { arguments: raw ?? null }
  try {
    const value = JSON.parse(raw)
    return value && typeof value === 'object' && !Array.isArray(value) ? value : { arguments: value }
  } catch {
    return { arguments: raw }
  }
}

function toolResultOf(event) {
  const block = event.data?.message?.content?.[0]
  return { callId: block?.toolCallId ?? event.data?.message?.source?.callId, isError: block?.isError === true }
}

export function apply(ctx, config) {
  const options = settings(config)
  const rootOf = session => {
    let current = session
    for (let depth = 0; depth < 8; depth += 1) {
      const parent = current?.header?.parentSession
      if (parent === undefined) return current?.id
      current = ctx.get('sessions')?.get?.(parent) ?? { id: parent }
    }
    return current?.id
  }
  const subagentOf = session => (session?.header?.parentSession !== undefined ? session.id : undefined)
  const children = new Set()
  const inFlight = new Set()
  const started = new Map() // session id -> { root, agent, cwd }
  const calls = new Map() // call id -> { name, input }
  let queueTail = Promise.resolve()
  let queued = 0

  const track = child => {
    children.add(child)
    child.on('close', () => children.delete(child))
  }

  const enqueue = event => {
    if (!SESSION_ID.test(event.session_id ?? '') || queued >= LIFECYCLE_QUEUE_LIMIT) return
    queued += 1
    queueTail = queueTail
      .then(() => runHook(options, 5, event, LIFECYCLE_TIMEOUT_MS))
      .catch(() => {})
      .finally(() => { queued -= 1 })
  }

  const emit = (session, hookEventName, extra = {}) => {
    const root = rootOf(session)
    const agent = subagentOf(session)
    enqueue({
      hook_event_name: hookEventName,
      session_id: root,
      cwd: session?.header?.cwd,
      ...(agent ? { agent_id: agent, agent_type: 'subagent' } : {}),
      ...extra,
    })
  }

  const announce = session => {
    if (!session?.id || started.has(session.id)) return
    started.set(session.id, { root: rootOf(session), agent: subagentOf(session), cwd: session.header?.cwd })
    emit(session, subagentOf(session) ? 'SubagentStart' : 'SessionStart')
  }

  const end = session => {
    if (!session?.id || !started.delete(session.id)) return
    emit(session, subagentOf(session) ? 'SubagentStop' : 'SessionEnd')
  }

  ctx.on('session/created', announce)
  ctx.on('session/disposed', end)
  ctx.on('session/event', (session, event) => {
    if (!session?.id || !event?.type) return
    announce(session)
    switch (event.type) {
      case 'turn/start':
        emit(session, 'UserPromptSubmit')
        break
      case 'turn/end': {
        const kind = event.data?.reason?.kind
        emit(session, kind === 'error' ? 'StopFailure' : 'Stop')
        break
      }
      case 'tool/call': {
        const input = parseArguments(event.data?.arguments)
        calls.set(event.data?.callId, { name: event.data?.name, input })
        emit(session, 'PreToolUse', { tool_name: event.data?.name, tool_input: input, tool_use_id: event.data?.callId })
        break
      }
      case 'tool/result': {
        const { callId, isError } = toolResultOf(event)
        const call = calls.get(callId)
        calls.delete(callId)
        emit(session, isError ? 'PostToolUseFailure' : 'PostToolUse', {
          tool_name: call?.name, tool_input: call?.input, tool_use_id: callId, tool_response: isError ? 'Error' : 'ok',
        })
        break
      }
      default:
        break
    }
  })

  const askIsland = (request, session, signal) => {
    const input = toolInputFor(session, request.callId)
    let child
    let cancelled = false
    const cancel = () => {
      cancelled = true
      try { child?.kill('SIGTERM') } catch {}
    }
    if (signal?.aborted) cancel()
    else signal?.addEventListener('abort', cancel, { once: true })
    // PreToolUse for this call is already queued: send it first so the broker can tie the card to its id.
    const hook = queueTail.then(() => cancelled ? null : runHook(options, options.timeout, {
      hook_event_name: 'PermissionRequest',
      session_id: rootOf(session),
      cwd: session.header?.cwd,
      tool_name: request.toolName,
      // Without a recorded call there is nothing else to show, so show why DSH is asking.
      tool_input: input ?? { reason: request.reason ?? '' },
      tool_use_id: request.callId,
      permission_mode: 'ask',
      ...(subagentOf(session) ? { agent_id: subagentOf(session), agent_type: 'subagent' } : {}),
    }, options.timeout * 1000 + 3000, c => {
      child = c
      track(c)
      if (cancelled) c.kill('SIGTERM')
    }))
    return { decision: hook.then(decisionFrom, () => null), cancel }
  }

  ctx.on('approval/request', function (request, next) {
    const session = request?.agent?.session
    if (!session?.id || request?.signal?.aborted) return next()
    const key = `${session.id}\0${request.callId ?? ''}\0${request.toolName}\0${request.reason ?? ''}`
    // Another plugin (Vibe Island's bridge) may re-dispatch this same request with a clone of it.
    // Only the first pass asks the island; the rest just pass through to the real answerer.
    if (inFlight.has(key)) return next()
    inFlight.add(key)

    return (async () => {
      const original = request.signal
      const nativeAbort = new AbortController()
      const forward = () => nativeAbort.abort(original?.reason)
      if (original?.aborted) forward()
      else original?.addEventListener('abort', forward, { once: true })

      // DSH's web answerer listens on `request.signal`. Handing it a signal we control lets its card
      // be withdrawn when the island decides first. `decide()` keeps racing the original signal.
      try { request.signal = nativeAbort.signal } catch { /* a frozen request only keeps the card up */ }

      const island = askIsland(request, session, nativeAbort.signal)
      const native = Promise.resolve().then(next).then(
        value => ({ kind: 'native', value }),
        error => ({ kind: 'error', error }),
      )

      try {
        // Run both to whichever gives a real decision first.
        const first = await Promise.race([
          native,
          island.decision.then(value => ({ kind: 'island', value })),
        ])
        if (first.kind === 'island') {
          if (first.value !== null) { nativeAbort.abort('island'); return first.value }
          const settled = await native
          if (settled.kind === 'error') throw settled.error
          return settled.value
        }
        if (first.kind === 'native' && first.value !== 'unavailable') { island.cancel(); return first.value }
        const decision = await island.decision
        if (decision !== null) return decision
        if (first.kind === 'error') throw first.error
        return 'unavailable'
      } finally {
        original?.removeEventListener('abort', forward)
        inFlight.delete(key)
      }
    })()
  }, { prepend: true })

  ctx.effect(() => () => {
    for (const child of children) { try { child.kill('SIGTERM') } catch {} }
    for (const { root, agent, cwd } of started.values()) {
      if (agent) continue
      enqueue({ hook_event_name: 'SessionEnd', session_id: root, cwd })
    }
    started.clear()
    return queueTail
  }, 'agent-island: session end on shutdown')
}
