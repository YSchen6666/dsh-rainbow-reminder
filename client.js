/**
 * DSH Desktop Reminder — browser half.
 *
 * Draws the same band the desktop assistant draws, inside the app page, for
 * people working in the browser where the always-on-top window is redundant.
 * Both halves read the same idea from one place: a kind decides the color, the
 * backdrop is a separate low-alpha plate, and the only colored thing is a
 * 2px hairline under the text.
 *
 * Transport: the Host half appends to a JSONL file, which a browser cannot
 * read. The page therefore polls a tiny read-only route the Host half exposes
 * on the same `webServer` the app already owns, so it inherits the app's own
 * admission rules instead of inventing a second auth path.
 */

window.__ModuleLoader__.load({
  id: '@local/dsh-rainbow-reminder',
  factory(require) {
    const React = require('react')
    const { createElement: h, useState, useEffect, useRef, useCallback } = React

    // `styles` and `console` are NOT shell seed words and are not declared in
    // dsh.client.external, so require() of either throws "missed the module
    // table" and kills the whole web boot. Inject CSS through a <style> node
    // and use the page's own console instead.
    const console2 = (typeof console !== 'undefined' && typeof console.error === 'function') ? console : null

    const NS = 'rainbowReminder'
    // `sessions` is a root service from dsh-api-session-controller (client half).
    // We subscribe to `ctx.sessions.list` to know when a session becomes
    // main-view-retained (retainedBy.mainView > 0) — that is the "open and view"
    // action. On first transition we POST to the Host resolve route so the
    // desktop assistant clears that session's reminders.
    const inject = ['locale', 'slots', 'sessions']

    // Mirrors desktop/config.json: same keys, same defaults, so a color change
    // in one place is a color change everywhere.
    const KINDS = {
      approval: { color: '#FFB454', en: 'APPROVAL', hold: 0, pulse: true },
      question: { color: '#FFB454', en: 'QUESTION', hold: 0, pulse: true },
      error:    { color: '#FF6B6B', en: 'ERROR', hold: 15000, pulse: true },
      blocked:  { color: '#FF3030', en: 'BLOCKED', hold: 0, pulse: true },
      waiting:  { color: '#FFB454', en: 'WAITING', hold: 0, pulse: true },
      team:     { color: '#9D8CFF', en: 'TEAM', hold: 6000, pulse: false },
      done:     { color: '#35D07F', en: 'DONE', hold: 6000, pulse: false },
      jobs:     { color: '#8E9BA8', en: 'JOBS', hold: 6000, pulse: false },
      schedule: { color: '#C792EA', en: 'SCHEDULE', hold: 6000, pulse: false },
      default:  { color: '#56D4E0', en: 'DSH', hold: 6000, pulse: false },
    }

    // Backdrop plate: the "transparent background color" knob, independent of
    // the kind color. 0.35 keeps it readable over dark and light themes.
    const BACKDROP = { color: '10,14,20', opacity: 0.35, height: 26 }
    const HAIRLINE_OPACITY = 0.85
    const LABEL_OPACITY = 0.92

    const DICT = {
      zh: {
        'meta.title': 'DSH 桌面提醒',
        'meta.description': '每类提示一种颜色：顶部出现一条发丝光带，等待授权为琥珀，完成为翠绿，出错为珊瑚红。',
        'sound.locked': '点击任意位置以开启提示音',
        'kind.approval': '等待授权',
        'kind.question': '等待回答',
        'kind.error': '任务出错',
        'kind.blocked': '任务无法继续',
        'kind.waiting': '等待处理',
        'kind.team': '队友消息',
        'kind.done': '任务完成',
        'kind.jobs': '后台任务结束',
        'kind.schedule': '定时任务触发',
        'kind.default': 'DSH 提示',
      },
      en: {
        'meta.title': 'DSH desktop reminder',
        'meta.description': 'One color per kind: a hairline band at the top — amber for approval, green for done, coral for errors.',
        'sound.locked': 'Click anywhere to enable the chime',
        'kind.approval': 'Awaiting approval',
        'kind.question': 'Awaiting your answer',
        'kind.error': 'Task failed',
        'kind.blocked': 'Task blocked',
        'kind.waiting': 'Waiting',
        'kind.team': 'Teammate message',
        'kind.done': 'Task complete',
        'kind.jobs': 'Background job done',
        'kind.schedule': 'Schedule fired',
        'kind.default': 'DSH notice',
      },
    }

    // ── audio ──────────────────────────────────────────────────────────────────
    function createChime() {
      let audioCtx = null
      let unlocked = false
      const notes = { ok: [659.25, 987.77], question: [523.25, 783.99], hand: [392, 523.25] }

      function ensure() {
        if (audioCtx === null || audioCtx.state === 'closed') {
          const Ctx = window.AudioContext ?? window.webkitAudioContext
          if (typeof Ctx !== 'function') return null
          audioCtx = new Ctx()
        }
        return audioCtx
      }

      return {
        get unlocked() { return unlocked },
        unlock() {
          unlocked = true
          const c = ensure()
          if (c !== null && c.state === 'suspended') void c.resume().catch(() => {})
        },
        play(sound) {
          try {
            const c = ensure()
            if (c === null) return
            if (c.state === 'suspended') { void c.resume().then(() => this.play(sound)).catch(() => {}); return }
            const seq = notes[sound] ?? notes.ok
            const t0 = c.currentTime
            seq.forEach((freq, i) => {
              const osc = c.createOscillator()
              const gain = c.createGain()
              osc.type = 'sine'
              osc.frequency.value = freq
              const start = t0 + i * 0.1
              gain.gain.setValueAtTime(0.0001, start)
              gain.gain.exponentialRampToValueAtTime(0.22, start + 0.02)
              gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.5)
              osc.connect(gain); gain.connect(c.destination)
              osc.start(start); osc.stop(start + 0.55)
            })
          } catch (error) { console2?.error?.('rainbow-reminder: chime failed', error) }
        },
        dispose() { try { audioCtx?.close() } catch { /* already closed */ } audioCtx = null },
      }
    }

    // ── styles ─────────────────────────────────────────────────────────────────
    // Tech-minimal: a flat plate, one 2px colored hairline, monospace label.
    // No gradient, no shadow on the plate, no rounded card, no movement.
    const CSS = `
.rbrr_layer{position:fixed;left:0;right:0;top:0;z-index:2147483000;pointer-events:none;font-family:Consolas,ui-monospace,SFMono-Regular,Menlo,monospace}
.rbrr_band{position:relative;display:flex;align-items:center;height:${BACKDROP.height}px;background:rgba(${BACKDROP.color},${BACKDROP.opacity});transition:opacity .24s linear}
.rbrr_band::after{content:"";position:absolute;left:0;right:0;bottom:0;height:2px;background:var(--rbrr-color);opacity:${HAIRLINE_OPACITY};transition:background-color .22s linear}
.rbrr_dot{width:6px;height:6px;background:var(--rbrr-color);opacity:${HAIRLINE_OPACITY};margin:0 8px 0 10px;flex:none}
.rbrr_label{font-size:11.5px;letter-spacing:.6px;color:#C9D4E2;opacity:${LABEL_OPACITY};white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rbrr_extra{margin-left:auto;margin-right:14px;font-size:11.5px;letter-spacing:.6px;color:var(--rbrr-color);opacity:${HAIRLINE_OPACITY}}
.rbrr_pulse{animation:rbrrPulse 1.2s ease-in-out infinite}
@keyframes rbrrPulse{0%,100%{opacity:1}50%{opacity:.55}}
.rbrr_sound{position:fixed;top:${BACKDROP.height + 6}px;left:50%;transform:translateX(-50%);font-size:11px;color:rgba(201,212,226,.65);pointer-events:none}
@media (prefers-reduced-motion: reduce){.rbrr_pulse{animation:none}}
`

    // ── component ──────────────────────────────────────────────────────────────
    // Registered the canonical way: the slot system renders this as a real
    // component (createElement) with the props returned by `inject`. It must
    // NOT be invoked as a plain function — that would run hooks outside React's
    // fiber tracking and crash the shell.
    function ReminderOverlay(props) {
      const { api, t } = props
      const [shown, setShown] = useState(null)     // { kind, session, at, id }
      const [soundLocked, setSoundLocked] = useState(true)
      const chimeRef = useRef(null)
      const timerRef = useRef(null)

      useEffect(() => {
        chimeRef.current = createChime()
        return () => { chimeRef.current?.dispose(); chimeRef.current = null }
      }, [])

      const activate = useCallback(data => {
        const kind = KINDS[data.kind] ? data.kind : 'default'
        const spec = KINDS[kind]
        setShown({ kind, session: data.sessionId ?? '', at: Date.now(), id: `${Date.now()}-${Math.random()}` })
        if (spec.pulse && chimeRef.current?.unlocked) chimeRef.current.play(kind === 'error' ? 'hand' : 'question')
        else if (chimeRef.current?.unlocked) chimeRef.current.play('ok')
        if (timerRef.current) clearTimeout(timerRef.current)
        if (spec.hold > 0) timerRef.current = setTimeout(() => setShown(null), spec.hold)
      }, [])

      // Poll the read-only route the Host half mounts; 1s is plenty for a band
      // that is already a courtesy, and it avoids holding a second stream open.
      useEffect(() => {
        let stop = false
        let cursor = 0
        const tick = async () => {
          try {
            const res = await fetch(`${api}/pending?since=${cursor}`, { cache: 'no-store' })
            if (!res.ok) return
            const body = await res.json()
            if (!stop && typeof body.cursor === 'number') cursor = body.cursor ?? cursor
            for (const item of body.events ?? []) {
              if (item.type === 'signal') activate(item)
              else if (item.type === 'resolve') { /* this half holds no queue */ }
            }
          } catch { /* app restarting; next tick retries */ }
        }
        tick()
        const id = setInterval(tick, 1000)
        return () => { stop = true; clearInterval(id) }
      }, [api, activate])

      useEffect(() => () => { if (timerRef.current) clearTimeout(timerRef.current) }, [])

      // First user gesture unlocks the chime (browser autoplay policy).
      useEffect(() => {
        const unlock = () => { chimeRef.current?.unlock(); setSoundLocked(false) }
        window.addEventListener('pointerdown', unlock, { once: true })
        window.addEventListener('keydown', unlock, { once: true })
        return () => {
          window.removeEventListener('pointerdown', unlock)
          window.removeEventListener('keydown', unlock)
        }
      }, [])

      if (shown === null) {
        return soundLocked
          ? h('div', { className: 'rbrr_layer' }, h('div', { className: 'rbrr_sound' }, t('sound.locked')))
          : null
      }

      const spec = KINDS[shown.kind] ?? KINDS.default
      const parts = [spec.en, t(`kind.${shown.kind}`)]
      if (shown.session) parts.push('#' + String(shown.session).replace(/^session-/, '').slice(0, 8))
      const time = new Date(shown.at).toTimeString().slice(0, 8)
      parts.push(time)

      return h('div', { className: 'rbrr_layer' },
        h('div', {
          className: 'rbrr_band' + (spec.pulse ? ' rbrr_pulse' : ''),
          style: { '--rbrr-color': spec.color },
          key: shown.id,
        },
          h('span', { className: 'rbrr_dot' }),
          h('span', { className: 'rbrr_label' }, parts.join('  ·  ')),
          shown.kind === 'approval' || shown.kind === 'question'
            ? h('span', { className: 'rbrr_extra' }, t('sound.locked'))
            : null),
        soundLocked ? h('div', { className: 'rbrr_sound' }, t('sound.locked')) : null)
    }

    // ── registration ───────────────────────────────────────────────────────────
    const API = (() => {
      try { return new URL('api/rainbow-reminder', document.baseURI).pathname } catch { return '/api/rainbow-reminder' }
    })()

    // Inject the stylesheet by hand: the shell seed table exposes no `styles`
    // module to plugin bundles, so `ctx.slots` never carries a CSS handle and
    // `require('styles')` is what crashed the boot. A scoped <style> element
    // is removed on teardown, matching the plugin's own lifetime.
    function insertCss(css) {
      const el = document.createElement('style')
      el.setAttribute('data-rbrr', 'rainbow-reminder')
      el.textContent = css
      document.head.appendChild(el)
      return () => { el.remove() }
    }

    function apply(ctx) {
      const t = ctx.locale.bind(NS)

      // Register dictionaries; the returned disposer becomes this effect's
      // cleanup, so a hot reload or fiber rebuild never double-registers NS.
      ctx.effect(() => ctx.locale.register(NS, { zh: DICT.zh, en: DICT.en }), 'rainbow-reminder: dictionaries')
      ctx.effect(() => insertCss(CSS), 'rainbow-reminder: styles')

      // ── watch when a session becomes main-view (user opens/views it) ──────────
      // The session controller tracks `retainedBy.mainView` per session.
      // When it transitions from 0 → >0 the human has that session in front.
      // We then POST to the Host resolve route so the desktop assistant clears
      // that session's reminders (done, approval, question, waiting).
      ctx.effect(() => {
        const sessions = ctx.sessions
        if (!sessions || !sessions.list) return

        // null = the first "ready" snapshot has not arrived yet. We treat that
        // first ready snapshot as the baseline (e.g. a session restored on app
        // startup must NOT clear its reminders), then only 0→>0 transitions
        // after it count as "the user just opened this session".
        let knownMain = null

        function currentMain() {
          const snap = sessions.list.getSnapshot()
          if (snap.phase !== 'ready') return null
          const out = new Set()
          for (const id of Object.keys(snap.byId ?? {})) {
            const row = snap.byId[id]
            if ((row?.retainedBy?.mainView ?? 0) > 0) out.add(id)
          }
          return out
        }

        const dispose = sessions.list.subscribe(() => {
          const now = currentMain()
          if (now === null) return
          if (knownMain === null) {
            knownMain = now
            return
          }
          for (const id of now) {
            if (!knownMain.has(id)) {
              // Newly viewed session: notify Host to resolve all kinds for it
              fetch(`${API}/resolve?sessionId=${encodeURIComponent(id)}`, {
                method: 'POST',
                cache: 'no-store',
              }).catch(() => { /* ignore network errors */ })
            }
          }
          knownMain = now
        })

        return dispose
      }, 'rainbow-reminder: view-watch')

      // `shell.overlay` is a real, owned frame-wide slot (dsh-client-ui-chat
      // hosts it for quota notices; context-menu and workspace dialogs also
      // inject into it). It is click-through, so the band never blocks the app
      // underneath. The canonical contract passes the component reference and
      // supplies its props through `inject`.
      ctx.slots.inject('shell.overlay', () => ctx.slots.register({
        name: 'shell.overlay',
        id: 'rainbow-reminder',
        locale: NS,
        inject: () => ({ api: API, t }),
      }, ReminderOverlay))
    }

    return { inject, apply }
  },
})
