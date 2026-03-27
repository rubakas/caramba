// Sync config stored in storage/sync_config.json (outside DB).

const fs = require('fs')
const path = require('path')
const db = require('../db')

function configPath() {
  return path.join(db.getStoragePath(), 'sync_config.json')
}

function readConfig() {
  try {
    if (!fs.existsSync(configPath())) return {}
    return JSON.parse(fs.readFileSync(configPath(), 'utf-8'))
  } catch {
    return {}
  }
}

function writeConfig(config) {
  const p = configPath()
  fs.mkdirSync(path.dirname(p), { recursive: true })
  fs.writeFileSync(p, JSON.stringify(config, null, 2))
}

function getSyncFolder() {
  return readConfig().sync_folder || null
}

function setSyncFolder(folder) {
  const config = readConfig()
  config.sync_folder = folder || null
  writeConfig(config)
}

function isEnabled() {
  const folder = getSyncFolder()
  return !!folder && fs.existsSync(folder)
}

function getLastSyncedAt() {
  const ts = readConfig().last_synced_at
  return ts || null
}

function setLastSyncedAt(time) {
  const config = readConfig()
  config.last_synced_at = time || new Date().toISOString()
  writeConfig(config)
}

module.exports = { getSyncFolder, setSyncFolder, isEnabled, getLastSyncedAt, setLastSyncedAt }
