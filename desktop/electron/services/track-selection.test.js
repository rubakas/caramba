const test = require('node:test')
const assert = require('node:assert/strict')

const { selectAudioTrack, selectSubtitleTrack } = require('./track-selection')

// ── selectAudioTrack ──────────────────────────────────────────────────

test('selectAudioTrack: returns null on empty input', () => {
  assert.equal(selectAudioTrack([], null), null)
  assert.equal(selectAudioTrack(null, null), null)
})

test('selectAudioTrack: prefers saved language', () => {
  const streams = [
    { index: 1, language: 'eng' },
    { index: 2, language: 'rus' },
  ]
  assert.equal(selectAudioTrack(streams, { audioLanguage: 'rus' }), 2)
})

test('selectAudioTrack: falls back to English when no preference', () => {
  const streams = [
    { index: 1, language: 'rus' },
    { index: 2, language: 'eng' },
  ]
  assert.equal(selectAudioTrack(streams, null), 2)
})

test('selectAudioTrack: falls back to first stream if no English', () => {
  const streams = [
    { index: 1, language: 'rus' },
    { index: 2, language: 'fra' },
  ]
  assert.equal(selectAudioTrack(streams, null), 1)
})

// ── selectSubtitleTrack ───────────────────────────────────────────────

test('selectSubtitleTrack: returns no sub when subtitleOff is set', () => {
  const streams = [{ index: 3, isText: true, language: 'eng' }]
  assert.deepEqual(
    selectSubtitleTrack(streams, { subtitleOff: true }),
    { index: null, isBitmap: false }
  )
})

test('selectSubtitleTrack: returns no sub when no streams exist', () => {
  assert.deepEqual(
    selectSubtitleTrack([], null),
    { index: null, isBitmap: false }
  )
})

test('selectSubtitleTrack: with no preference, auto-picks text sub', () => {
  const streams = [
    { index: 3, isText: true, language: 'eng' },
    { index: 4, isText: false, language: 'eng' },
  ]
  assert.deepEqual(
    selectSubtitleTrack(streams, null),
    { index: 3, isBitmap: false }
  )
})

// THIS is the regression test for the 4K-HEVC stall bug.
test('selectSubtitleTrack: with no preference, NEVER auto-picks bitmap sub', () => {
  // Aladdin/4K case: source has only PGS (bitmap) subs. Auto-burning one
  // forces full_transcode → VideoToolbox can't keep up at 4K → stall.
  // The right default is "no subtitle" — user must opt in explicitly.
  const streams = [
    { index: 3, isText: false, codec: 'hdmv_pgs_subtitle', language: 'eng' },
  ]
  assert.deepEqual(
    selectSubtitleTrack(streams, null),
    { index: null, isBitmap: false }
  )
})

test('selectSubtitleTrack: prefers saved text sub over bitmap of same language', () => {
  const streams = [
    { index: 3, isText: false, language: 'eng' },
    { index: 4, isText: true, language: 'eng' },
  ]
  assert.deepEqual(
    selectSubtitleTrack(streams, { subtitleLanguage: 'eng' }),
    { index: 4, isBitmap: false }
  )
})

test('selectSubtitleTrack: explicit bitmap preference still allowed', () => {
  // The user explicitly chose this bitmap track — burn it.
  // The full_transcode cost is a deliberate trade.
  const streams = [
    { index: 5, isText: false, language: 'eng' },
  ]
  assert.deepEqual(
    selectSubtitleTrack(streams, { subtitleLanguage: 'eng' }),
    { index: 5, isBitmap: true }
  )
})
