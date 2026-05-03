// Technical probe (codec, duration, resolution) via ffprobe.
// Mirror of server/app/services/tech_probe_service.rb. Reuses
// transcoder.js's `probe()` so binary discovery and the TCC fd dance
// stay in one place.
//
// Public API:
//   probe(filePath)            -> Promise<probe-data | null>
//   probeFor(record)           -> Promise<probe-data | null>
//                                 Reads cached tech_metadata if size matches,
//                                 otherwise probes live and updates the row.
//   probeAndCache(table, id)   -> Promise<probe-data | null>
//                                 Convenience for IPC handlers.
//
// Concurrency-capped: only N ffprobes run in parallel to avoid spawning
// hundreds of processes during a fresh-library scan.

const transcoder = require('./transcoder')
const db = require('../db')

const MAX_CONCURRENCY = 4
let inflight = 0
const queue = []

function withSlot(fn) {
  return new Promise((resolve, reject) => {
    const run = () => {
      inflight += 1
      Promise.resolve()
        .then(fn)
        .then((v) => { inflight -= 1; pump(); resolve(v) })
        .catch((e) => { inflight -= 1; pump(); reject(e) })
    }
    if (inflight < MAX_CONCURRENCY) run()
    else queue.push(run)
  })
}

function pump() {
  while (inflight < MAX_CONCURRENCY && queue.length > 0) {
    queue.shift()()
  }
}

function safeSize(filePath) {
  try {
    const fs = require('fs')
    return fs.statSync(filePath).size
  } catch {
    return 0
  }
}

async function probe(filePath) {
  if (!filePath) return null
  return withSlot(async () => {
    try {
      const data = await transcoder.probe(filePath)
      if (!data) return null
      data.size_bytes = safeSize(filePath)
      data.probed_at = new Date().toISOString()
      return data
    } catch (e) {
      console.warn(`[TechProbe] ${filePath} -> ${e.message}`)
      return null
    }
  })
}

function parseCached(record) {
  if (!record || !record.tech_metadata) return null
  try { return JSON.parse(record.tech_metadata) } catch { return null }
}

// Cache rules: skip probe if cached and the size matches. Otherwise
// re-probe and rewrite the row.
async function probeAndCache(table, id) {
  if (!table || !id) return null
  const record = db[table] && db[table].findById ? db[table].findById(id) : null
  if (!record || !record.file_path) return null

  const cached = parseCached(record)
  if (cached && cached.size_bytes === safeSize(record.file_path)) {
    return cached
  }

  const data = await probe(record.file_path)
  if (!data) return null

  const attrs = { tech_metadata: JSON.stringify(data) }
  if (data.duration && Number(data.duration) > 0) {
    attrs.duration_seconds = Math.round(Number(data.duration))
  }

  if (db[table] && db[table].update) {
    db[table].update(id, attrs)
  }
  return data
}

async function probeFor(record) {
  if (!record || !record.file_path) return null
  const cached = parseCached(record)
  if (cached && cached.size_bytes === safeSize(record.file_path)) {
    return cached
  }
  return probe(record.file_path)
}

module.exports = { probe, probeFor, probeAndCache }
