/**
 * DSH Desktop Reminder — Host half.
 *
 * Watches the durable log of every live Session and reduces it to a small set
 * of "you may want to look at your screen" signals, then appends each one to a
 * local JSONL file that the desktop assistant tails.
 *
 * Why a file and not HTTP: the desktop web server answers 401 to every request
 * from a plain local process, including `/`. The assistant is a separate
 * program, so it must not try to borrow the app's browser credentials. A file
 * in the user's own profile is the honest boundary — same user, same machine,
 * no authentication to fake, and it keeps working when the app restarts on a
 * different port.
 *
 * Signal kinds and where they come from:
 *   approval  ← `session/event` `approval/asked`       (durable record)
 *   question  ← `session/event` `tool/call` / `tool/ptc-dispatch` when
 *               `name === 'ask_user_question'` (keyed by callId / subCallId)
 *   done      ← `turn/end` reason.kind === 'completed'
 *   error     ← `turn/end` reason.kind === 'error' | 'blocked', or a failed
 *               `tool/result` for an ask_user_question call
 *   jobs      ← `session/event` `job/settled`          (background job finished)
 *   team      ← `session/event` `team/task` / `team/message/queued`
 *   schedule  ← host event `schedule/changed`
 *
 * Resolution: `session/event` `approval/decided` (by id), `tool/result` (by
 * toolCallId), and a `user/message` whose `source.kind === 'user-question-reply'`
 * (by source.callId). Any new `turn/start` or `user/message` in the same session
 * clears that session's pending items — if the turn moved on, the human already
 * acted.
 *
 * Architecture note: every listener uses `{ global: true }` so it receives
 * events from every scoped fiber regardless of its own fiber's scope tag.
 * Without this, root-scoped listeners would be silently filtered out by
 * cordis's scoped event dispatch when the event is emitted from a child scope.
 */

import { appendFile, mkdir, readFile, rename, stat } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { spawn } from 'node:child_process'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const NS = 'rainbow-reminder'
const MAX_BYTES = 2 * 1024 * 1024

export const name = 'rainbow-reminder'

function stateDir() {
  const base = process.env.LOCALAPPDATA || path.join(homedir(), 'AppData', 'Local')
  return path.join(base, 'dsh-rainbow-reminder')
}

// ── desktop assistant supervision ────────────────────────────────────────────
// The desktop band lives in a separate PowerShell/WPF process (desktop/reminder.ps1).
// Nothing about it is automatic on a stock Windows box: without an autostart
// registry entry the assistant simply never runs, and the user only ever sees
// the in-page band, which dies the moment the DSH window loses focus. Since
// this Host half runs inside DSH anyway, it supervises the assistant: launch
// it if the pidfile is missing/stale, re-check periodically, and never spawn
// two copies (the assistant holds a named mutex that makes duplicate spawns
// exit on their own).
const SUPERVISE_INTERVAL_MS = 30_000
const HEARTBEAT_STALE_MS = 15_000
const SUPERVISE_MIN_GAP_MS = 5_000

function scriptDir() {
  try { return path.dirname(fileURLToPath(import.meta.url)) } catch { return process.cwd() }
}

function assistantPaths() {
  const dir = path.join(scriptDir(), 'desktop')
  return {
    script: path.join(dir, 'reminder.ps1'),
    config: path.join(dir, 'config.json'),
  }
}

async function readAssistantHeartbeat(pidFile) {
  try {
    const raw = await readFile(pidFile, 'utf8')
    const data = JSON.parse(raw)
    const pid = Number(data?.pid)
    const at = Date.parse(data?.at)
    if (!Number.isInteger(pid) || pid <= 0 || !Number.isFinite(at)) return null
    return { pid, at }
  } catch { return null }
}

function processAlive(pid) {
  try { return process.kill(pid, 0) } catch (err) {
    // EPERM means the process exists but we may not signal it — still alive.
    return err?.code === 'EPERM'
  }
}

function spawnAssistant(paths, logger) {
  if (!existsSync(paths.script)) {
    logger.warn?.(`rainbow-reminder: assistant script missing at ${paths.script}`)
    return false
  }
  try {
    // 通过 desktop/start.ps1 启动助手。start.ps1 内部用 Start-Process
    // (ShellExecute) 拉起 reminder.ps1，让助手进程脱离 DSH 的 Job Object。
    //
    // 之前的实现在这里有两个 Windows 专属的坑，已被实验证实：
    //   1. detached:true 会给子进程分配独立控制台 (DETACHED_PROCESS)，与
    //      -WindowStyle Hidden / windowsHide 冲突，导致 powershell 一启动就
    //      崩溃退出（连 mutex 之后的日志都来不及写）——supervisor 每 30s
    //      spawn 一次全是"秒死"，看起来就像"插件没运行"。
    //   2. 若去掉 detached 直接 spawn，助手会继承 DSH 的 KILL_ON_JOB_CLOSE
    //      Job，DSH 一重启就连带杀掉助手。
    // 二者都绕开：让一个短命的 powershell 进程用 ShellExecute 把助手"交给
    // 系统"，助手不再属于 DSH 的 Job Object。
    const launcher = path.join(path.dirname(paths.script), 'start.ps1')
    if (!existsSync(launcher)) {
      logger.warn?.(`rainbow-reminder: assistant launcher missing at ${launcher}`)
      return false
    }
    const args = ['-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
      '-File', launcher]
    if (existsSync(paths.config)) args.push('-ConfigPath', paths.config)
    const child = spawn('powershell.exe', args, {
      stdio: 'ignore',
      windowsHide: true,
    })
    // spawn() reports async failures (EPERM etc.) on the error event, not as a
    // throw — without this listener a blocked spawn dies silently and the
    // supervisor would retry every 30s for nothing.
    child.on('error', (err) => {
      logger.warn?.(`rainbow-reminder: assistant launcher failed: ${err?.message ?? err}`)
    })
    child.unref()
    logger.info?.('rainbow-reminder: assistant spawn requested')
    return true
  } catch (err) {
    logger.warn?.(`rainbow-reminder: cannot spawn assistant: ${err?.message ?? err}`)
    return false
  }
}

function superviseAssistant(logger) {
  const paths = assistantPaths()
  const pidFile = path.join(stateDir(), 'assistant.pid')
  let lastSpawnAt = 0

  const check = async () => {
    try {
      const beat = await readAssistantHeartbeat(pidFile)
      const fresh = beat !== null && (Date.now() - beat.at) < HEARTBEAT_STALE_MS
      // Only a FRESH heartbeat proves the assistant is really alive. A stale
      // heartbeat must NOT be trusted even if some process holds that pid:
      // Windows reuses pids, so `processAlive(oldPid)` can be true for a
      // completely unrelated process, which previously made the supervisor
      // believe the assistant was "wedged but alive" and never respawn it.
      // The assistant's named mutex already prevents duplicate instances, so
      // spawning on a stale/missing heartbeat is always safe.
      if (fresh && processAlive(beat.pid)) return
      const now = Date.now()
      if (now - lastSpawnAt < SUPERVISE_MIN_GAP_MS) return
      lastSpawnAt = now
      logger.info?.(`rainbow-reminder: assistant not running (beat=${beat ? 'stale' : 'none'}), spawning`)
      await spawnAssistant(paths, logger)
    } catch (err) {
      logger.warn?.(`rainbow-reminder: supervise check failed: ${err?.message ?? err}`)
    }
  }

  // Immediate synchronous spawn attempt on plugin load, bypassing the 5s gap.
  // This ensures the assistant is running even if the first periodic check
  // hasn't fired yet or was skipped for any reason.
  try { spawnAssistant(paths, logger) } catch { /* best effort */ }

  void check()
  const timer = setInterval(() => void check(), SUPERVISE_INTERVAL_MS)
  if (typeof timer.unref === 'function') timer.unref()
  return () => clearInterval(timer)
}

export function apply(ctx, config) {
  const logger = ctx.logger ?? console
  const sessions = ctx.get?.('sessions')

  const quietMs = Number.isFinite(config?.quietMs) && config.quietMs >= 0 ? config.quietMs : 1200
  const desktopAssistant = config?.desktopAssistant !== false // on by default
  /**
   * Alert policy (v13). What the window is allowed to interrupt you for.
   *
   * `done` used to fire on *every* `turn/end` with reason `completed`. In one
   * real conversation that is one green prompt per delegated subagent plus one
   * per intermediate plan step, so the moment the human actually cares about —
   * "this conversation is finished" — was buried in the noise.
   *
   *   onlyWhenAllTasksDone
   *     A `todo/write` snapshot written during the ending turn with any
   *     `pending`/`in_progress` item means the agent is mid-plan (it usually
   *     stopped to ask something), so the turn ending is not "all tasks done".
   *     The judgement is scoped to that turn because DSH's own `todos`
   *     projection resets on the next `turn/start`; a plan that is never
   *     rewritten stops being authoritative instead of blocking `done` forever
   *     (failing open — a missing prompt is worse than a slightly early one).
   *   fromSubagents
   *     Subagent sessions (`header.origin === 'subagent'` / `delegationDepth > 0`)
   *     never announce completion themselves: the delegating tool call has not
   *     returned yet, so the parent conversation is still working and owns the
   *     prompt. The parent's own `turn/end` arrives once the child is done.
   *   quietJobsDuringTurn
   *     Every `pwsh` call registers a job and settles it a second later, so
   *     `job/settled` used to flash the window once per shell command in the
   *     middle of the work. Two independent tests keep it quiet, each of which
   *     fails open: the settling job's tool call is still in flight (it IS the
   *     command the turn is waiting for), or its session already has an open
   *     turn (the work is visibly ongoing). A background job settles only after
   *     its own `tool/result` was recorded, so it still gets its prompt.
   *
   * A session that is still waiting on the human (approval / question / waiting)
   * is skipped for `done` too — those kinds have their own prompt.
   */
  const alertPolicy = config?.alertPolicy ?? {}
  const doneOnlyWhenAllTasksDone = alertPolicy.onlyWhenAllTasksDone !== false
  const doneFromSubagents = alertPolicy.fromSubagents === true
  const quietJobsDuringTurn = alertPolicy.quietJobsDuringTurn !== false
  const dir = typeof config?.signalDir === 'string' && config.signalDir ? config.signalDir : stateDir()
  const signalFile = path.join(dir, 'signal.jsonl')
  const snapshotFile = path.join(dir, 'snapshot.json')

  /**
   * Monotonic sequence so the assistant can drop duplicates across channels.
   *
   * The assistant ignores any line whose `seq` is <= the highest it has already
   * seen. If a fresh DSH process restarts this counter from 0 while the desktop
   * assistant keeps running, the assistant would silently drop every new signal
   * — the exact "绿云出现但没反应" failure. The only authoritative record is the
   * signal file itself (and its rotated sibling), so scan them on startup instead
   * of trusting a separate counter file that can drift out of sync.
   */
  function maxSeqFromFile(file) {
    try {
      const raw = readFileSync(file, 'utf8')
      let max = 0
      for (const line of raw.split('\n')) {
        const s = line.trim()
        if (!s) continue
        try {
          const obj = JSON.parse(s)
          const q = Number(obj?.seq)
          if (Number.isFinite(q) && q > max) max = q
        } catch { /* skip malformed line */ }
      }
      return max
    } catch { return 0 }
  }
  const seqFile = path.join(dir, 'seq.jsonl')
  let seq = (() => {
    let max = maxSeqFromFile(signalFile)
    if (existsSync(`${signalFile}.1`)) max = Math.max(max, maxSeqFromFile(`${signalFile}.1`))
    // Fall back to the old counter file only if the signal files are empty.
    if (max === 0) {
      try {
        const raw = readFileSync(seqFile, 'utf8')
        const last = Number(raw.split('\n').filter(Boolean).pop())
        if (Number.isFinite(last) && last > 0) max = last
      } catch { /* missing */ }
    }
    return max
  })()
  /**
   * kind -> Map<key, item> of currently pending items, mirrored to snapshot.json.
   * Each item stores its stable key AND both identities (sessionId, id) so it can
   * be resolved by either one: an id-keyed approval is also cleared when its
   * session moves on (turn/start, user/message), and a session-keyed item is
   * cleared when its id decides (approval/decided).
   */
  const pending = new Map()
  /** `${kind}|${sessionId}` -> last emit ms, for de-bouncing bursts. */
  const lastEmit = new Map()
  /** Queue of lines to append; the writer is serialized to keep lines whole. */
  let writeChain = Promise.resolve()
  let disposed = false

  function nowSeq() {
    const next = ++seq
    return next
  }

  async function ensureDir() {
    try { await mkdir(dir, { recursive: true }) } catch (err) {
      logger.warn?.(`rainbow-reminder: cannot create ${dir}: ${err?.message ?? err}`)
    }
  }

  async function rotateIfNeeded() {
    try {
      const info = await stat(signalFile)
      if (info.size < MAX_BYTES) return
      await rename(signalFile, `${signalFile}.1`)
      logger.info?.('rainbow-reminder: rotated signal file')
    } catch { /* missing file is the normal case */ }
  }

  /** In-memory ring of recent events, for the browser half's poll route. */
  const ring = []
  const RING_MAX = 200

  function record(obj) {
    ring.push(obj)
    if (ring.length > RING_MAX) ring.splice(0, ring.length - RING_MAX)
    return obj
  }

  function writeLine(obj) {
    record(obj)
    const line = JSON.stringify(obj) + '\n'
    writeChain = writeChain.then(async () => {
      if (disposed) return
      try {
        await ensureDir()
        await rotateIfNeeded()
        await appendFile(signalFile, line, 'utf8')
      } catch (err) {
        logger.warn?.(`rainbow-reminder: append failed: ${err?.message ?? err}`)
      }
    })
    return writeChain
  }

  function writeSnapshot() {
    const list = []
    for (const [kind, items] of pending) {
      // Only the kinds that are meant to survive a restart belong here. A
      // transient kind (`done` above all) sitting in the snapshot would be
      // restored by the assistant and re-light a completion that is already
      // over — the very thing the completion gate is trying to stop.
      if (!PERSIST_KINDS.has(kind)) continue
      for (const item of items.values()) list.push({ kind, key: item.key, sessionId: item.sessionId, id: item.id })
    }
    const body = JSON.stringify({ at: Date.now(), pending: list }) + '\n'
    writeChain = writeChain.then(async () => {
      if (disposed) return
      try {
        await ensureDir()
        const tmp = `${snapshotFile}.${process.pid}.tmp`
        await appendFile(tmp, body, 'utf8')
        await rename(tmp, snapshotFile)
      } catch { /* snapshot is an optimization, never required */ }
    })
    return writeChain
  }

  /**
   * Kinds that key per-session (via keyFor) so they can be resolved by
   * session id — includes `done` so that `turn/start`/`user/message` can
   * stop the green cloud of the specific session that just completed, and
   * `error`/`blocked` so the red cloud can be dismissed when the human opens
   * that session to read what went wrong.
   */
  const WAITING_KINDS = new Set(['approval', 'question', 'waiting', 'done', 'error', 'blocked'])

  /**
   * Kinds whose pending state survives a host restart and is written to
   * snapshot.json. `done`/`jobs`/`team` vanish on their own after their
   * hold window, so tracking them would only light the band for something
   * already over after a restart. `error`/`blocked` are persistent-until-
   * viewed, like approval/question/waiting, so they belong here too.
   */
  const PERSIST_KINDS = new Set(['approval', 'question', 'waiting', 'error', 'blocked'])

  function keyFor(kind, sessionId, id) {
    if (WAITING_KINDS.has(kind)) {
      if (id) return `${kind}|id|${id}`
      if (sessionId) return `${kind}|sid|${sessionId}`
    }
    return `${kind}|g|`
  }

  function signal(kind, detail = {}) {
    const sessionId = detail.sessionId ?? ''
    const id = detail.id ?? ''
    const dedupe = `${kind}|${sessionId}`
    const now = Date.now()
    const last = lastEmit.get(dedupe) ?? 0
    if (now - last < quietMs) return
    lastEmit.set(dedupe, now)

    const key = keyFor(kind, sessionId, id)
    if (WAITING_KINDS.has(kind)) {
      if (!pending.has(kind)) pending.set(kind, new Map())
      pending.get(kind).set(key, { key, sessionId, id })
      if (PERSIST_KINDS.has(kind)) void writeSnapshot()
    } else {
      pending.delete(kind)
    }

    void writeLine({
      type: 'signal', kind, seq: nowSeq(), at: now,
      sessionId, id, text: detail.text ?? '',
    })
  }

  function resolve(kind, detail = {}) {
    const sessionId = detail.sessionId ?? ''
    const id = detail.id ?? ''
    const items = pending.get(kind)
    let removed = 0
    if (items !== undefined) {
      for (const [key, item] of [...items]) {
        const match = (id && item.id === id)
          || (!id && sessionId && item.sessionId === sessionId)
          || (!id && !sessionId)
        if (match) { items.delete(key); removed++ }
      }
      if (items.size === 0) pending.delete(kind)
    }
    if (removed === 0) return
    void writeLine({ type: 'resolve', target: kind, seq: nowSeq(), at: Date.now(), sessionId, id })
    void writeSnapshot()
  }

  function resolveSession(sessionId, kinds = ['approval', 'question', 'waiting']) {
    if (!sessionId) return
    for (const kind of kinds) resolve(kind, { sessionId })
  }

  // ── "is the whole conversation finished?" ─────────────────────────────────
  /** sessionId -> { todos, turn, at } : latest `todo/write` snapshot and the turn that wrote it. */
  const plans = new Map()
  /** Turn counter per session, so a plan is only binding for the turn that wrote it. */
  const turnOf = new Map()
  /** sessionId -> true while a turn is running (drives `quietJobsDuringTurn`). */
  const turnOpen = new Map()
  /**
   * Tool calls that have started but not returned yet.
   *
   * This is what tells a foreground command apart from a background one without
   * guessing: `tool/call` → `job/registered` → `job/settled` → `tool/result`, so
   * a job whose callId is still in flight IS the command you are waiting for; a
   * job that settles after its tool/result was recorded finished behind your back.
   */
  const toolCallsInFlight = new Set()
  const PLAN_TTL_MS = 6 * 60 * 60 * 1000

  function noteTodoWrite(sessionId, todos) {
    if (!sessionId) return
    const turn = turnOf.get(sessionId) ?? 0
    plans.set(sessionId, { todos, turn, at: Date.now() })
    if (plans.size > 400) {
      const cutoff = Date.now() - PLAN_TTL_MS
      for (const [id, plan] of plans) if (plan.at < cutoff) plans.delete(id)
    }
  }

  function noteTurnStart(sessionId) {
    if (!sessionId) return
    turnOf.set(sessionId, (turnOf.get(sessionId) ?? 0) + 1)
    turnOpen.set(sessionId, true)
  }

  function noteTurnEnd(sessionId) {
    if (!sessionId) return
    turnOpen.set(sessionId, false)
  }

  function isSubagentSession(session) {
    const header = session?.header ?? {}
    if (header.origin === 'subagent') return true
    const depth = Number(header.delegationDepth)
    return Number.isFinite(depth) && depth > 0
  }

  /** Open (`pending`/`in_progress`) plan items written by the turn that is ending. */
  function openPlanItems(sessionId) {
    const plan = plans.get(sessionId)
    if (plan === undefined) return 0
    if (plan.turn !== (turnOf.get(sessionId) ?? 0)) return 0 // stale plan: not authoritative any more
    return plan.todos.filter((todo) => todo?.status !== 'completed').length
  }

  /** The waiting kind this session is currently blocked on, or '' when it is free. */
  function waitingKindFor(sessionId) {
    for (const kind of ['approval', 'question', 'waiting']) {
      const items = pending.get(kind)
      if (items === undefined) continue
      for (const item of items.values()) if (item.sessionId === sessionId) return kind
    }
    return ''
  }

  /**
   * Why this session must not announce completion, '' when it may.
   * @param session - the Session whose turn just ended.
   * @param sessionId - its id.
   */
  function doneBlockedBy(session, sessionId) {
    if (!doneOnlyWhenAllTasksDone) return ''
    if (!doneFromSubagents && isSubagentSession(session)) return 'subagent'
    const waiting = waitingKindFor(sessionId)
    if (waiting !== '') return `waiting:${waiting}`
    const open = openPlanItems(sessionId)
    if (open > 0) return `plan:${open}-open`
    return ''
  }

  // ── session events ────────────────────────────────────────────────────────
  // Global listener: receives every session's event regardless of current scope.
  const offSession = ctx.on('session/event', (session, event) => {
    const sessionId = session?.header?.id ?? session?.id ?? ''
    const type = event?.type
    const data = event?.data

    switch (type) {
      case 'turn/start':
      case 'user/message': {
        // New task or continuing this conversation: stop the persistent done blink,
        // and clear any error/blocked cloud for this session — once the human has
        // moved on (sent a message or started a new turn), the failure was seen.
        resolve('done', { sessionId })
        resolveSession(sessionId, ['approval', 'question', 'waiting', 'error', 'blocked'])
        // DSH's `todos` projection resets on `turn/start`; mirror that so a plan
        // left over from an earlier turn can never block a later completion.
        if (type === 'turn/start') noteTurnStart(sessionId)
        // When a user answers a question explicitly: source.kind = 'user-question-reply'
        const source = data?.source
        if (source?.kind === 'user-question-reply' && typeof source?.callId === 'string') {
          resolve('question', { sessionId, id: source.callId })
        }
        return
      }

      // The agent rewrote its task list (whole-list replacement, owned by this
      // session). Keep it: it decides whether an ending turn means "all tasks
      // done" or "still mid-plan".
      case 'todo/write': {
        const todos = Array.isArray(data?.todos) ? data.todos : []
        noteTodoWrite(sessionId, todos)
        return
      }

      case 'approval/asked':
        signal('approval', {
          sessionId,
          id: data?.id ?? '',
          text: typeof data?.toolName === 'string' ? data.toolName : '',
        })
        return

      case 'approval/decided':
        resolve('approval', { sessionId, id: data?.id ?? '' })
        return

      // Timed question (ask_user_question as tool): tool/call with name="ask_user_question"
      case 'tool/call': {
        const callId = data?.callId
        if (typeof callId === 'string' && callId !== '') {
          toolCallsInFlight.add(callId)
          if (toolCallsInFlight.size > 500) {
            // A forgotten call must not pin a job as "foreground" forever.
            const oldest = toolCallsInFlight.values().next().value
            if (oldest !== undefined) toolCallsInFlight.delete(oldest)
          }
        }
        if (data?.name === 'ask_user_question') {
          signal('question', {
            sessionId,
            id: data?.callId ?? '',
            text: '',
          })
        }
        return
      }

      // Non-timed (foreground) question: tool/ptc-dispatch with name="ask_user_question"
      case 'tool/ptc-dispatch':
        if (data?.name === 'ask_user_question') {
          signal('question', {
            sessionId,
            id: data?.subCallId ?? '',
            text: '',
          })
        }
        return

      // Any tool result for an ask_user_question clears the waiting question band.
      case 'tool/result': {
        const callId = data?.message?.toolCallId
        const isError = data?.error || data?.message?.isError
        if (typeof callId === 'string') {
          toolCallsInFlight.delete(callId)
          const questionView = pending.get('question')
          if (questionView !== undefined) {
            for (const [key, item] of [...questionView]) {
              if (item.id === callId) {
                // If the result is an error, show an error band; otherwise clear.
                if (isError) signal('error', { sessionId })
                resolve('question', { sessionId, id: callId })
                break
              }
            }
          }
        }
        return
      }

      case 'turn/end': {
        const reason = data?.reason
        const kind = reason && typeof reason === 'object' ? reason.kind : reason
        noteTurnEnd(sessionId)
        if (kind === 'completed') {
          // Only the conversation that actually finished everything rings the
          // completion prompt — see `alertPolicy` above for the three conditions.
          const blockedBy = doneBlockedBy(session, sessionId)
          if (blockedBy === '') signal('done', { sessionId })
          else logger.info?.(`rainbow-reminder: done gated (${blockedBy}) session=${sessionId}`)
        } else if (kind === 'error') signal('error', { sessionId })
        else if (kind === 'blocked') signal('blocked', { sessionId })
        // aborted / interrupted / forked / max-tokens stay silent on purpose:
        // the human stopped it or the agent continued by itself.
        resolveSession(sessionId)
        return
      }

      case 'job/settled': {
        // Every shell command is a job, so announcing each one turned the window
        // into a strobe light while the agent was working. Two independent rules
        // keep it quiet, each failing open:
        //   1. the job still has its tool call in flight → it IS the command the
        //      turn is waiting for (background jobs settle after their tool/result
        //      was recorded, so this does not hide them);
        //   2. the session already has an open turn → the work is visibly ongoing.
        const callId = data?.toolCall?.callId ?? data?.toolCall?.rootCallId
        if (quietJobsDuringTurn && typeof callId === 'string' && toolCallsInFlight.has(callId)) return
        if (quietJobsDuringTurn && turnOpen.get(sessionId) === true) return
        signal('jobs', { sessionId })
        return
      }

      case 'team/task':
      case 'team/message/queued':
        signal('team', { sessionId })
        return

      default:
        return
    }
  }, { global: true })

  // ── schedules ─────────────────────────────────────────────────────────────
  // Host event (plural, not session scoped). Needs { global: true } so it
  // doesn't get filtered by the fiber's scope.
  const offSchedule = ctx.on('schedule/changed', () => {
    signal('schedule', {})
  }, { global: true })

  // ── browser poll route ────────────────────────────────────────────────────
  // The page cannot read the JSONL file, so it long-polls this. Same-origin
  // only: `webServer` dispatch already runs behind the app's admission fence,
  // and the response carries nothing but the kinds this plugin just emitted.
  ctx.inject(['webServer'], (scoped) => {
    const server = scoped.webServer
    if (server === undefined || typeof server.register !== 'function') {
      logger.warn?.('rainbow-reminder: webServer unavailable; in-page band disabled')
      return
    }
    const route = (path, handler) => {
      try {
        scoped.effect(() => server.register({ kind: 'exact', path, handler }), `rainbow-reminder: ${path}`)
        logger.info?.(`rainbow-reminder: route ${path}`)
      } catch (err) {
        logger.warn?.(`rainbow-reminder: cannot mount ${path}: ${err?.message ?? err}`)
      }
    }

    route('/api/rainbow-reminder/pending', (req, res) => {
      let since = 0
      try {
        const q = String(req.url ?? '').split('?')[1] ?? ''
        const m = /(?:^|&)since=(\d+)/.exec(q)
        if (m !== null) since = Number(m[1])
      } catch { /* malformed query means "from the start" */ }
      const events = ring.filter((e) => typeof e.seq === 'number' && e.seq > since)
      const cursor = ring.length === 0 ? since : Math.max(since, ...ring.map((e) => e.seq ?? 0))
      const body = JSON.stringify({ cursor, events })
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
      res.end(body)
    })

    route('/api/rainbow-reminder/health', (_req, res) => {
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
      // `policy` is reported so "is the alert gate actually live?" is a single
      // request instead of a guess: after editing index.js the plugin must be
      // reloaded (Plugin Manager enable/disable or a DSH restart) for it to show.
      res.end(JSON.stringify({
        ok: NS,
        version: 3,
        signalFile,
        policy: { onlyWhenAllTasksDone: doneOnlyWhenAllTasksDone, fromSubagents: doneFromSubagents, quietJobsDuringTurn },
      }))
    })

    // Clear every reminder that is tied to a session when the user opens/views
    // that session (client-initiated): done, plus the persistent approval /
    // question / waiting kinds. Once the human has the session in front of them
    // and is operating on it, the alert has served its purpose.
    route('/api/rainbow-reminder/resolve', (req, res) => {
      let sessionId = ''
      try {
        const q = String(req.url ?? '').split('?')[1] ?? ''
        const m = /(?:^|&)sessionId=([^&]+)/.exec(q)
        if (m !== null) sessionId = decodeURIComponent(m[1])
      } catch { /* ignore */ }
      if (!sessionId) {
        res.writeHead(400, { 'content-type': 'application/json; charset=utf-8' })
        return res.end(JSON.stringify({ error: 'missing sessionId' }))
      }
      resolveSession(sessionId, ['done', 'approval', 'question', 'waiting', 'error', 'blocked'])
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
      res.end(JSON.stringify({ ok: true, sessionId }))
    })
  })

  // ── desktop assistant supervision ─────────────────────────────────────────
  // The WPF band only covers the whole screen when reminder.ps1 is running.
  // Supervise it from here so a running DSH is all the "installer" needed.
  const offSupervise = desktopAssistant ? superviseAssistant(logger) : null

  void ensureDir().then(() => {
    // A fresh process starts from a clean slate: replaying last run's pending
    // items would light the band for something already handled.
    void writeSnapshot()
    logger.info?.(`rainbow-reminder: writing signals to ${signalFile}`)
  })

  const teardown = () => {
    disposed = true
    offSession?.()
    offSchedule?.()
    offSupervise?.()
    void writeSnapshot()
  }
  if (typeof ctx.effect === 'function') ctx.effect(() => teardown, 'rainbow-reminder: teardown')
  else process.once('exit', teardown)

  return { signalFile, snapshotFile }
}
