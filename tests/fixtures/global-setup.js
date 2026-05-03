const { ensureRails, ensureViteWeb, ensureViteDesktop } = require('./server')

module.exports = async () => {
  await ensureRails()
  // Web project depends on Vite web (:3000); Electron project depends on Vite desktop (:5173).
  // The global setup is run once per `playwright test` invocation, so we always start both.
  await ensureViteWeb()
  await ensureViteDesktop()
}
