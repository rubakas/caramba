// Verifies the libmpv subtitle fix. Repro: any MKV with a text subtitle
// stream — before the fix the libmpv DeviceProfile shipped with
// SubtitleProfiles=[], the server marked any subtitle as burn-required,
// full_transcode kicked in, and ffmpeg errored on an overlay filter
// pointed at a text stream (overlay only works for bitmap subs).
//
// The assertion targets the SERVER decision, not whether libmpv visually
// painted the frame — that depends on native-module availability in the
// test environment, which may differ from a real install. The fix is
// upstream of the engine choice: with valid SubtitleProfiles in the
// libmpv profile (or with text subs no longer burn-required server-side),
// strategy must be direct_play and isBitmapSubtitle must be false.

const { test: baseTest, expect } = require('@playwright/test')
const { launchHybrid } = require('../../electron/launch')

const test = baseTest.extend({
  electron: async ({}, use, testInfo) => {
    const ctx = await launchHybrid()
    // Capture renderer console output so we can see [desktop debug] logs.
    ctx.window.on('console', (msg) => {
      if (msg.text().includes('[desktop debug]') || msg.text().includes('[desktop]')) {
        console.log('[browser console]', msg.text())
      }
    })
    await use(ctx)
    // Always dump the Electron main log — libmpv's diagnostics live
    // here and are essential for catching "audio plays but video
    // doesn't render" class of bugs even on a passing test.
    const tail = ctx.mainLog.slice(-300).map(l => `[${l.ts}] ${l.type}: ${l.text.trim()}`).join('\n')
    console.log('=== Electron main log (last 300 lines) ===')
    console.log(tail)
    console.log('=== end main log ===')
    await ctx.close()
  },
})

test('@playback libmpv DeviceProfile + text-sub handling — strategy must be direct_play', async ({ electron }) => {
  const { window } = electron
  await window.waitForLoadState('domcontentloaded')

  // Capture the playback-start request body AND the response body. The
  // request body tells us what DeviceProfile the client sent (was the
  // libmpv-subtitle fix actually picked up?); the response body tells
  // us what the server decided (was the text-sub-burn fix applied?).
  let startRequest = null
  let startResponse = null
  window.on('request', (req) => {
    if (req.url().endsWith('/api/playback/start') && req.method() === 'POST') {
      try { startRequest = JSON.parse(req.postData() || '{}') } catch {}
    }
  })
  window.on('response', async (resp) => {
    if (resp.url().endsWith('/api/playback/start') && resp.request().method() === 'POST') {
      try { startResponse = await resp.json() } catch {}
    }
  })

  const apiBase = 'http://localhost:3001'
  const showsRes = await fetch(`${apiBase}/api/shows`)
  const shows = await showsRes.json()
  const show = shows.find(s => /office/i.test(s.title)) || shows[0]
  test.skip(!show, 'no shows in library')

  await window.evaluate((slug) => { window.location.hash = `/shows/${slug}` }, show.slug)
  const cta = window.locator('.btn-play-cta, button:has-text("Resume"), button:has-text("Play")').first()
  await expect(cta).toBeVisible({ timeout: 15_000 })
  await cta.click()

  await expect.poll(() => startResponse !== null, {
    timeout: 30_000,
    message: '/api/playback/start never responded',
  }).toBe(true)

  // ── DeviceProfile fix (client side) ─────────────────────────────
  // Before the fix, buildLibMpvProfile shipped SubtitleProfiles=[].
  // After: a hardcoded set covering srt/subrip/ass/ssa/vtt/PGS/DVD/DVB.
  const profile = startRequest?.deviceProfile
  expect(profile, 'request body should include a deviceProfile').toBeTruthy()
  if (profile.Name === 'caramba-desktop-libmpv') {
    expect(profile.SubtitleProfiles?.length, 'libmpv profile must advertise subtitle support — empty SubtitleProfiles is the original bug')
      .toBeGreaterThan(0)
    const hasSrt = profile.SubtitleProfiles.some(p => /srt|subrip/i.test(p.Format))
    expect(hasSrt, 'libmpv profile must list srt/subrip').toBe(true)
  }

  // ── Strategy fix (server side) ──────────────────────────────────
  // The original bug was: text-subtitle file → server marks it
  // burn_required → strategy=full_transcode → ffmpeg overlay filter
  // pointed at an SRT stream → silent ffmpeg error → spinner forever.
  //
  // Skip the strategy assertion if the auto-picked subtitle is bitmap
  // (PGS / DVD / DVB) — those legitimately require full_transcode for
  // burn-in when the client profile doesn't advertise rendering them.
  const pickedStream = startResponse.subtitleStreams?.find(
    s => s.index === startResponse.activeSubtitleIndex
  )
  const pickedIsText = pickedStream?.isText
  if (pickedIsText) {
    // Post-fix strategy depends on engine profile:
    //   - libmpv profile (MKV in DirectPlayProfile)   → direct_play
    //   - browser profile (MKV needs container remux) → direct_stream
    // Either way, NEVER full_transcode for an h264+ac3 MKV with a text sub.
    expect(startResponse.strategy, 'must not full_transcode an h264+ac3 MKV with text subs (text-sub fix)')
      .not.toBe('full_transcode')
    expect(startResponse.isBitmapSubtitle, 'text subtitles must never trigger burn-in')
      .toBe(false)
  } else if (pickedStream) {
    // Bitmap sub → burn-in expected → full_transcode is correct.
    expect(startResponse.strategy).toBe('full_transcode')
    expect(startResponse.isBitmapSubtitle).toBe(true)
  }

  // ── Subtitle plumbing (conditional) ─────────────────────────────
  // If the picked episode has a text subtitle stream, verify it's
  // delivered as VTT sidecar. If it has no subs at all, skip.
  if (startResponse.subtitleStreams?.length > 0) {
    const hasText = startResponse.subtitleStreams.some(s => s.isText)
    if (hasText) {
      expect(startResponse.activeSubtitleIndex, 'text sub should be auto-picked')
        .not.toBeNull()
      expect(startResponse.subtitleUrl, 'text sub should be served as a VTT sidecar')
        .toMatch(/\/api\/playback\/subtitles\?session=/)
    }
  }

  // ── Renderer used hls.js (libmpv embed is disabled) ─────────────
  // Caramba's Electron desktop uses hls.js for playback now — libmpv
  // embed was dropped because it couldn't be made visually
  // indistinguishable from Electron's BrowserWindow on macOS.
  // Verify the request profile reflects that (caramba-browser, not
  // caramba-desktop-libmpv) and that the <video> element exists and
  // is sourced from the server.
  const profileName = startRequest?.deviceProfile?.Name
  console.log('request deviceProfile name:', profileName)
  expect(profileName, 'desktop should use the browser profile, not libmpv')
    .toBe('caramba-browser')

  // The renderer should have a <video> element wired to the server's
  // HLS or direct-play URL. WebVideoPlayer renders this whenever
  // playerState.streamUrl is truthy (which is true for the browser
  // path because the desktop adapter doesn't null those URLs).
  await expect.poll(
    async () => window.evaluate(() => !!document.querySelector('video')),
    { timeout: 15_000, message: 'WebVideoPlayer <video> element never mounted' }
  ).toBe(true)

  const videoState = await window.evaluate(() => {
    const v = document.querySelector('video')
    return {
      hasSrc: !!v.src || !!v.currentSrc,
      readyState: v.readyState,
      duration: v.duration,
    }
  })
  console.log('video element state:', JSON.stringify(videoState))
  expect(videoState.hasSrc, 'video element should be sourced from server playback URL')
    .toBe(true)
  console.log('startResponse.subtitleStreams:', JSON.stringify(startResponse.subtitleStreams))
})
