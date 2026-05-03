const fs = require('fs')
const path = require('path')

class DiagnosticSummaryReporter {
  onTestEnd(test, result) {
    const dir = result.attachments.find(a => a.name === 'trace')?.path
      ? path.dirname(result.attachments.find(a => a.name === 'trace').path)
      : test.outputDir
    if (!dir) return

    const partialPath = path.join(dir, 'summary.partial.json')
    const partial = fs.existsSync(partialPath) ? JSON.parse(fs.readFileSync(partialPath, 'utf8')) : {}
    const ffmpegLogPath = path.join(dir, 'ffmpeg.server.log')
    const ffmpegLog = fs.existsSync(ffmpegLogPath) ? fs.readFileSync(ffmpegLogPath, 'utf8') : ''

    const errors = result.errors.map(e => ({
      message: e.message || String(e),
      stack: e.stack,
      location: e.location,
    }))

    const summary = {
      ...partial,
      status: result.status,
      duration: result.duration,
      retry: result.retry,
      errors,
      ffmpegLines: ffmpegLog.split('\n').filter(Boolean).slice(0, 500),
      attachments: result.attachments.map(a => ({ name: a.name, path: a.path, contentType: a.contentType })),
    }

    fs.writeFileSync(path.join(dir, 'summary.json'), JSON.stringify(summary, null, 2))
  }
}

module.exports = DiagnosticSummaryReporter
