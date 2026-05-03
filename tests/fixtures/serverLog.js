const fs = require('fs')
const path = require('path')

const LOG_PATH = path.resolve(__dirname, '..', '..', 'server', 'log', 'development.log')
const FILTER = /\[(Transcoder|Subtitle)\]/

function startTail() {
  const offset = fs.existsSync(LOG_PATH) ? fs.statSync(LOG_PATH).size : 0
  return { logPath: LOG_PATH, startOffset: offset }
}

function captureSince({ logPath, startOffset }) {
  if (!fs.existsSync(logPath)) return ''
  const fd = fs.openSync(logPath, 'r')
  try {
    const stat = fs.fstatSync(fd)
    if (stat.size <= startOffset) return ''
    const length = stat.size - startOffset
    const buf = Buffer.alloc(Math.min(length, 8 * 1024 * 1024))  // cap at 8MB per test
    fs.readSync(fd, buf, 0, buf.length, startOffset)
    const text = buf.toString('utf8')
    return text.split('\n').filter(l => FILTER.test(l)).join('\n')
  } finally {
    fs.closeSync(fd)
  }
}

module.exports = { startTail, captureSince }
