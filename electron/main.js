const { app, BrowserWindow, shell, dialog } = require('electron');
const { spawn, execSync } = require('child_process');
const path = require('path');
const net = require('net');

// --- Configuration ---
const RAILS_PORT = 4741;
const RAILS_ENV = 'development';

// In dev mode, Rails root is the project root.
// In packaged mode, it's inside extraResources/rails.
function railsRoot() {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, 'rails');
  }
  return path.join(__dirname, '..');
}

let mainWindow = null;
let railsProcess = null;

// --- Rails Server Management ---

function isPortInUse(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => resolve(true));
    server.once('listening', () => {
      server.close();
      resolve(false);
    });
    server.listen(port, '127.0.0.1');
  });
}

async function waitForServer(port, timeoutMs = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const inUse = await isPortInUse(port);
    if (inUse) return true;
    await new Promise((r) => setTimeout(r, 300));
  }
  return false;
}

function startRails() {
  const root = railsRoot();
  const env = Object.assign({}, process.env, {
    RAILS_ENV: RAILS_ENV,
    PORT: String(RAILS_PORT),
    RAILS_LOG_TO_STDOUT: '1',
  });

  // Use bin/rails server
  const railsBin = path.join(root, 'bin', 'rails');

  console.log(`[Electron] Starting Rails server at ${root} on port ${RAILS_PORT}`);

  railsProcess = spawn(railsBin, ['server', '-p', String(RAILS_PORT), '-b', '127.0.0.1'], {
    cwd: root,
    env: env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  railsProcess.stdout.on('data', (data) => {
    process.stdout.write(`[Rails] ${data}`);
  });

  railsProcess.stderr.on('data', (data) => {
    process.stderr.write(`[Rails] ${data}`);
  });

  railsProcess.on('error', (err) => {
    console.error('[Electron] Failed to start Rails:', err.message);
    dialog.showErrorBox('Rails Error', `Could not start the Rails server:\n${err.message}`);
    app.quit();
  });

  railsProcess.on('exit', (code, signal) => {
    console.log(`[Electron] Rails process exited (code=${code}, signal=${signal})`);
    railsProcess = null;
  });
}

function stopRails() {
  if (!railsProcess) return;
  console.log('[Electron] Stopping Rails server...');
  // Send SIGTERM; Rails/Puma handles graceful shutdown
  railsProcess.kill('SIGTERM');

  // Force-kill after 5 seconds if still alive
  setTimeout(() => {
    if (railsProcess) {
      console.log('[Electron] Force-killing Rails server');
      railsProcess.kill('SIGKILL');
      railsProcess = null;
    }
  }, 5000);
}

// --- Window ---

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 800,
    minHeight: 600,
    backgroundColor: '#000000',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 16, y: 16 },
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  mainWindow.loadURL(`http://127.0.0.1:${RAILS_PORT}`);

  // Open new windows (target="_blank") in system browser instead
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// --- App Lifecycle ---

app.on('ready', async () => {
  // Check if Rails is already running (dev mode with manual server)
  const alreadyRunning = await isPortInUse(RAILS_PORT);

  if (alreadyRunning) {
    console.log(`[Electron] Rails already running on port ${RAILS_PORT}`);
  } else {
    startRails();
    console.log('[Electron] Waiting for Rails server...');
    const ready = await waitForServer(RAILS_PORT, 30000);
    if (!ready) {
      dialog.showErrorBox('Startup Error', 'Rails server did not start within 30 seconds.');
      app.quit();
      return;
    }
  }

  createWindow();
});

app.on('window-all-closed', () => {
  stopRails();
  app.quit();
});

app.on('before-quit', () => {
  stopRails();
});

app.on('activate', () => {
  if (mainWindow === null) {
    createWindow();
  }
});
