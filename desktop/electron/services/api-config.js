// API mode config stored in storage/api_config.json (outside DB).
// Controls whether the desktop app uses the Rails API instead of local SQLite.

const fs = require('fs')
const path = require('path')
const db = require('../db')

function configPath() {
  return path.join(db.getStoragePath(), 'api_config.json')
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

function getServerUrl() {
  return readConfig().server_url || null
}

function setServerUrl(url) {
  const config = readConfig()
  config.server_url = url || null
  writeConfig(config)
}

function isEnabled() {
  return !!readConfig().enabled
}

function setEnabled(enabled) {
  const config = readConfig()
  config.enabled = !!enabled
  writeConfig(config)
}

function getLocalPlayback() {
  const config = readConfig()
  // Default to true — prefer local transcoder when file is accessible
  return config.local_playback !== false
}

function setLocalPlayback(value) {
  const config = readConfig()
  config.local_playback = !!value
  writeConfig(config)
}

/** Return full config for the renderer */
function getAll() {
  const config = readConfig()
  return {
    enabled: !!config.enabled,
    server_url: config.server_url || null,
    local_playback: config.local_playback !== false,
  }
}

module.exports = { getServerUrl, setServerUrl, isEnabled, setEnabled, getLocalPlayback, setLocalPlayback, getAll }
