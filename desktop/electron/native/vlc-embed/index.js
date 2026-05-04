// Loader for the @caramba/vlc-embed native module. Resolves the build
// output regardless of where the workspace lives (dev vs packaged).
const path = require('path')
const native = require('./build/Release/vlc_embed.node')
module.exports = native
