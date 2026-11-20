/**
 * Request trust fence for the plugin's HTTP surface.
 *
 * The plugin registers an exact route under `/api/rainbow-reminder/...`, which
 * is *longer* than the kernel's `/api` prefix — webServer dispatch is
 * exact-over-table, then longest-prefix — so these routes run before the
 * connection service's own admission check and would otherwise answer any
 * loopback caller. This module closes that boundary with the same two layers
 * the our-free-model plugin uses:
 *
 * 1. the composition's own `connection` service when present — the exact
 *    admission decision the kernel applies to its `/api` routes;
 * 2. a structural replica of that fence for compositions without the service:
 *    loopback host only, no cross-site fetches, and an `Origin`/`Referer` that
 *    matches the `Host` authority whenever the client supplies one.
 */

const LOOPBACK_NAMES = new Set(['127.0.0.1', '[::1]', '::1', 'localhost'])

export function connectionAdmissionView(service) {
  return {
    get admit() {
      const current = typeof service === 'function' ? service() : service
      if (current === undefined) return undefined
      if (typeof current.admit !== 'function' && typeof current.requestRejection === 'function') {
        return req => {
          const status = current.requestRejection(req)
          return status === undefined ? undefined : { rejection: status }
        }
      }
      return req => current.admit(req)
    },
  }
}

/**
 * Decide one request. Returns an HTTP status to reject with, or `undefined` to
 * let the handler run.
 */
export function rejectionFor(req, connection, onRejection) {
  let decision
  try {
    const admit = connection?.admit
    if (typeof admit === 'function') {
      const admission = admit.call(connection, req)
      const status = admission && typeof admission === 'object' ? admission.rejection : undefined
      if (status === undefined) return undefined
      decision = { status, source: 'connection', reason: 'host-rejected' }
    } else {
      const reject = connection?.requestRejection
      if (typeof reject === 'function') {
        const status = reject.call(connection, req)
        if (status === undefined) return undefined
        decision = { status, source: 'connection', reason: 'host-rejected' }
      }
    }
  } catch {
    // Never bypass browser authentication when a mounted Host service fails.
    decision = { status: 503, source: 'connection', reason: 'admission-error' }
  }
  if (decision === undefined) {
    const reason = structuralReason(req)
    if (reason === undefined) return undefined
    decision = { status: 403, source: 'structural', reason }
  }
  try {
    onRejection?.(decision)
  } catch {
    // Diagnostics are observational.
  }
  return decision.status
}

/** Return a fixed reason without exposing caller-supplied strings. */
function structuralReason(req) {
  const host = authorityOf(req.headers.host, 'http')
  if (host === null || !LOOPBACK_NAMES.has(host.hostname)) return 'host-not-loopback'
  const site = String(req.headers['sec-fetch-site'] ?? '').toLowerCase()
  if (site === 'cross-site') return 'cross-site'
  for (const header of ['origin', 'referer']) {
    const raw = req.headers[header]
    if (typeof raw !== 'string' || raw.trim() === '') continue
    if (header === 'referer' && isDesktopRelayReferer(raw)) {
      if (req.headers.origin !== undefined || req.headers['sec-fetch-site'] !== undefined) return 'desktop-relay-markers'
      continue
    }
    const authority = authorityOf(raw.trim())
    if (authority === null) return `${header}-invalid`
    if (authority.scheme !== host.scheme || authority.hostname !== host.hostname || authority.port !== host.port) return `${header}-mismatch`
  }
  return undefined
}

/** Only the owned application page, never arbitrary custom-protocol pages. */
function isDesktopRelayReferer(value) {
  try {
    const url = new URL(value)
    return url.protocol === 'dsh-app:' && url.hostname === 'app' && url.port === ''
      && url.username === '' && url.password === ''
  } catch {
    return false
  }
}

/** Split a Host/Origin/Referer value into {scheme, hostname, port}, defaulting the port. */
function authorityOf(value, defaultScheme) {
  if (typeof value !== 'string' || value.trim() === '') return null
  let url
  try {
    url = new URL(value.includes('://') ? value.trim() : `${defaultScheme ?? 'http'}://${value.trim()}`)
  } catch {
    return null
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null
  const port = url.port === '' ? (url.protocol === 'https:' ? '443' : '80') : url.port
  return { scheme: url.protocol.replace(':', ''), hostname: url.hostname.toLowerCase(), port }
}
