const path = require('path')
const { defineConfig, devices } = require('@playwright/test')

const ROOT = path.resolve(__dirname, '..')

module.exports = defineConfig({
  globalSetup: require.resolve('./fixtures/global-setup.js'),
  globalTeardown: require.resolve('./fixtures/global-teardown.js'),
  testDir: './specs',
  outputDir: './test-results',
  timeout: 90_000,
  fullyParallel: false,
  workers: 1,
  reporter: [
    ['list'],
    ['html', { outputFolder: './playwright-report', open: 'never' }],
    ['./reporters/diagnostic-summary.js'],
  ],
  use: {
    trace: 'on',
    video: 'on',
    screenshot: 'only-on-failure',
    actionTimeout: 10_000,
    navigationTimeout: 20_000,
  },
  projects: [
    {
      name: 'web',
      testDir: './specs/web',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'http://localhost:3000',
        // Headed: more representative perf (hw video decode, real audio path).
        // Harness runs locally on the user's machine, so a popup window is fine.
        headless: false,
        recordHar: {
          mode: 'minimal',
          content: 'omit',
        },
      },
    },
    {
      name: 'electron',
      testDir: './specs/electron',
    },
  ],
})
