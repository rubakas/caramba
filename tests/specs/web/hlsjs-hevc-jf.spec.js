const { test, expect } = require('@playwright/test')

test('@web hls.js plays HEVC SDR fmp4 from jellyfin-ffmpeg', async ({ page }) => {
  page.on('console', m => console.log('LOG:', m.text()))
  const startResp = await page.request.post('http://localhost:3001/api/playback/start', {
    data: { filePath: '/Volumes/1TB/Everything Everywhere All at Once (2022) BDRip 1080p H.265 [UKR_ENG] [Hurtom].mkv', startTime: 0,
      deviceProfile: { Name:'caramba-browser',
        DirectPlayProfiles:[{Container:'mp4',Type:'Video',VideoCodec:'h264,hevc',AudioCodec:'aac'}],
        TranscodingProfiles:[
          {Container:'ts',Type:'Video',Protocol:'hls',VideoCodec:'h264',AudioCodec:'aac,ac3',MaxAudioChannels:'6'},
          {Container:'mp4',Type:'Video',Protocol:'hls',VideoCodec:'h264,hevc',AudioCodec:'aac,ac3,eac3',MaxAudioChannels:'6'},
        ],
        SubtitleProfiles:[], CodecProfiles:[] }}
  })
  const session = await startResp.json()
  console.log('STRATEGY', session.strategy)
  await page.setContent(`<video id="v" controls autoplay style="width:100%"></video><pre id="s"></pre>
<script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js"></script>
<script>
  const v = document.getElementById('v'), s = document.getElementById('s')
  const hls = new Hls({ startPosition: 0 })
  hls.loadSource('${session.hlsUrl}'); hls.attachMedia(v)
  hls.on(Hls.Events.MANIFEST_PARSED, () => v.play().catch(e => console.log('play rej', e.message)))
  hls.on(Hls.Events.ERROR, (_,d) => console.log('HLS_ERR', d.type, d.details, 'fatal=' + d.fatal))
  setInterval(() => { s.textContent = JSON.stringify({t:v.currentTime,d:v.duration,rs:v.readyState}) }, 1000)
</script>`)
  await page.waitForTimeout(10000)
  console.log('FINAL', await page.evaluate(() => document.getElementById('s').textContent))
})
