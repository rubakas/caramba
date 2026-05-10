// Loader for the mpv-embed native module. Resolves the build output
// regardless of where the workspace lives (dev vs packaged).
const path = require('path')
const native = require('./build/Release/mpv_embed.node')
module.exports = native
