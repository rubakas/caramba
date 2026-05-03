// Audio + subtitle track selection at playback start.
// Mirrored on the Rails side in Api::PlaybackController#select_subtitle_track —
// keep both implementations aligned: auto-burning a bitmap subtitle (PGS,
// VOBSUB) forces full_transcode, and on a 4K HEVC source VideoToolbox can't
// keep up with realtime, so the player stalls.
// See memory: project_first_movie_full_transcode_bug.md

function selectAudioTrack(audioStreams, prefs) {
  if (!audioStreams || audioStreams.length === 0) return null
  if (prefs && prefs.audioLanguage) {
    const saved = audioStreams.find(s => s.language === prefs.audioLanguage)
    return saved ? saved.index : audioStreams[0].index
  }
  const eng = audioStreams.find(s => s.language === 'eng' || s.language === 'en')
  return eng ? eng.index : audioStreams[0].index
}

// Returns { index, isBitmap } or { index: null, isBitmap: false }.
//
// Rules:
//   - subtitleOff preference → no subtitle
//   - prefs.subtitleLanguage → first text sub matching, else first bitmap sub matching
//   - no preference → ONLY auto-pick a text sub. Never auto-burn a bitmap sub:
//     bitmap subs require pixel composition, forcing full_transcode, which
//     stalls 4K HEVC playback (VideoToolbox can't keep up with realtime).
//     The user must explicitly request a bitmap sub for it to be burned.
function selectSubtitleTrack(subtitleStreams, prefs) {
  if (!subtitleStreams || subtitleStreams.length === 0) {
    return { index: null, isBitmap: false }
  }
  if (prefs && prefs.subtitleOff) {
    return { index: null, isBitmap: false }
  }
  if (prefs && prefs.subtitleLanguage) {
    const savedText = subtitleStreams.find(s => s.isText && s.language === prefs.subtitleLanguage)
    if (savedText) return { index: savedText.index, isBitmap: false }
    const savedBitmap = subtitleStreams.find(s => !s.isText && s.language === prefs.subtitleLanguage)
    if (savedBitmap) return { index: savedBitmap.index, isBitmap: true }
    return { index: null, isBitmap: false }
  }
  // No preference: auto-pick a text sub if there is one, otherwise no sub.
  // Explicitly do NOT fall back to a bitmap sub — see comment above.
  const textSub = subtitleStreams.find(s => s.isText)
  if (textSub) return { index: textSub.index, isBitmap: false }
  return { index: null, isBitmap: false }
}

module.exports = { selectAudioTrack, selectSubtitleTrack }
