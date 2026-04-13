import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { refractive } from '../config/refractive'
import Navbar from '../components/Navbar'
import { useGlassConfig } from '../config/useGlassConfig'
import NowPlaying from '../components/NowPlaying'
import SeasonTabs from '../components/SeasonTabs'
import EpisodeRow from '../components/EpisodeRow'
import { usePlayer } from '../context/PlayerContext'
import { useToast } from '../context/ToastContext'
import { useApi, useCapabilities } from '../context/ApiContext'
import { genresList, premiereYear, statusClass, formatTime, progressPercent, truncate } from '../utils'

const PlaySvg = ({ size = 20 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
)

export default function SeriesShow() {
  const { slug } = useParams()
  const navigate = useNavigate()
  const api = useApi()
  const { canPlay, canManage, canDownload, hasNowPlaying } = useCapabilities()
  const { openPlayer, launching } = usePlayer()
  const { showToast } = useToast()
  const [series, setSeries] = useState(null)
  const [episodes, setEpisodes] = useState([])
  const [seasons, setSeasons] = useState([])
  const [resumeEp, setResumeEp] = useState(null)
  const [nextEp, setNextEp] = useState(null)
  const [activeSeason, setActiveSeason] = useState(null)
  const [loading, setLoading] = useState(true)
  const [vlcAvailable, setVlcAvailable] = useState(false)
  const [downloadProgress, setDownloadProgress] = useState({}) // episodeId -> progress (0-1)
  
  // Ref for auto-focusing primary CTA on Android TV
  const primaryCtaRef = useRef(null)
  const isTV = typeof window !== 'undefined' && window.Capacitor?.isNativePlatform?.() === true

  const loadData = useCallback(async () => {
    try {
      const [data, hasVlc] = await Promise.all([
        api.getSeriesShow(slug),
        api.checkVlc(),
      ])
      if (!data) { navigate('/'); return }
      setSeries(data.series)
      setEpisodes(data.episodes)
      setSeasons(data.seasons)
      setResumeEp(data.resumeEp)
      setNextEp(data.nextEp)
      setVlcAvailable(hasVlc)

      // Determine active season: last watched episode's season, or first season
      setActiveSeason(prev => {
        if (prev !== null) return prev
        const lastWatched = [...data.episodes].filter(e => e.watched).sort((a, b) => {
          if (a.season_number !== b.season_number) return b.season_number - a.season_number
          return b.episode_number - a.episode_number
        })[0]
        return lastWatched?.season_number ?? data.seasons[0] ?? 1
      })
    } catch (err) {
      console.error('Failed to load series:', err)
    } finally {
      setLoading(false)
    }
  }, [slug, navigate, api])

  useEffect(() => {
    loadData()
    const handleStop = () => loadData()
    window.addEventListener('playback-stopped', handleStop)
    const unsubVlc = api.onVlcPlaybackEnded(() => loadData())

    // Listen for download progress events
    const unsubDl = api.onMediaDownloadProgress((data) => {
      if (data.episodeId) {
        if (data.status === 'downloading') {
          setDownloadProgress(prev => ({ ...prev, [data.episodeId]: data.progress }))
        } else {
          // On complete/failed, clear live progress and reload data
          setDownloadProgress(prev => {
            const next = { ...prev }
            delete next[data.episodeId]
            return next
          })
          loadData()
        }
      }
    })

    return () => {
      window.removeEventListener('playback-stopped', handleStop)
      unsubVlc()
      unsubDl()
    }
  }, [loadData, api])

  // Auto-focus primary CTA button on Android TV after data loads
  useEffect(() => {
    if (isTV && !loading && series && primaryCtaRef.current) {
      // Small delay to ensure DOM is ready
      const timer = setTimeout(() => {
        // Focus without scrolling, then scroll to top so hero stays visible
        primaryCtaRef.current?.focus({ preventScroll: true })
        window.scrollTo({ top: 0, behavior: 'instant' })
      }, 100)
      return () => clearTimeout(timer)
    }
  }, [isTV, loading, series])

  const handlePlay = async (episodeId) => {
    const result = await api.playEpisode(episodeId)
    if (!result || result.error) {
      showToast(result?.error || 'Failed to start playback', { type: 'error' })
      return
    }
    await openPlayer({
      type: 'episode',
      episodeId: { id: result.episode_id, whId: result.watch_history_id },
      seriesId: result.series_id,
      filePath: result.file_path,
      startTime: result.start_time,
      title: series?.name || '',
      subtitle: episodes.find(e => e.id === episodeId)?.code + ' — ' + (episodes.find(e => e.id === episodeId)?.title || ''),
    })
    loadData()
  }

  const handleToggle = async (episodeId) => {
    await api.toggleEpisode(episodeId)
    loadData()
  }

  const handleOpenInVlc = async (episodeId) => {
    const ep = episodes.find(e => e.id === episodeId)
    if (!ep?.file_path) return
    const result = await api.openInVlc({ filePath: ep.file_path, episodeId })
    if (result?.error) showToast(result.error, { type: 'error' })
  }

  const handleOpenInDefault = async (episodeId) => {
    const ep = episodes.find(e => e.id === episodeId)
    if (!ep?.file_path) return
    const result = await api.openInDefault(ep.file_path, episodeId)
    if (result?.error) showToast(result.error, { type: 'error' })
  }

  const handleDownloadEpisode = async (episodeId) => {
    // Find the episode to get its file_path (needed for hybrid mode where server IDs differ from local)
    const ep = episodes.find(e => e.id === episodeId)
    showToast('Starting download...', { type: 'info', duration: 2000 })
    // Pass serverEpisodeId for downloading from server when local file is not available
    const result = await api.downloadEpisode({ episodeId, filePath: ep?.file_path, serverEpisodeId: episodeId })
    if (result?.error) {
      showToast(result.error, { type: 'error' })
    } else if (result?.ok) {
      showToast('Download complete', { type: 'success' })
      loadData()
    }
  }

  const handleDeleteDownloadEpisode = async (episodeId) => {
    // Find the episode to get its file_path (needed for hybrid mode where server IDs differ from local)
    const ep = episodes.find(e => e.id === episodeId)
    await api.deleteDownloadEpisode({ episodeId, filePath: ep?.file_path })
    showToast('Download deleted', { type: 'info', duration: 2000 })
    loadData()
  }

  const handleDownloadSeason = async (seasonNumber) => {
    if (!series) return
    showToast(`Downloading Season ${seasonNumber}...`, { type: 'info', duration: 3000 })
    // Pass seriesSlug for hybrid mode where server IDs differ from local
    const result = await api.downloadSeason({ seriesId: series.id, seriesSlug: series.slug, seasonNumber })
    if (result?.error) {
      showToast(result.error, { type: 'error' })
    } else if (result?.results) {
      const ok = result.results.filter(r => r.ok).length
      const skipped = result.results.filter(r => r.skipped).length
      const failed = result.results.filter(r => r.error).length
      let msg = `Season ${seasonNumber}: ${ok} downloaded`
      if (skipped > 0) msg += `, ${skipped} skipped`
      if (failed > 0) msg += `, ${failed} failed`
      showToast(msg, { type: failed > 0 ? 'error' : 'success' })
      loadData()
    }
  }

  const handleDeleteSeasonDownloads = async (seasonNumber) => {
    if (!series) return
    // Pass seriesSlug for hybrid mode where server IDs differ from local
    await api.deleteDownloadSeason({ seriesId: series.id, seriesSlug: series.slug, seasonNumber })
    showToast(`Season ${seasonNumber} downloads deleted`, { type: 'info', duration: 2000 })
    loadData()
  }

  const handleScan = async () => {
    await api.scanSeries(slug)
    loadData()
  }

  const handleRefresh = async () => {
    await api.refreshSeriesMetadata(slug)
    loadData()
  }

  const handleRemove = async () => {
    if (!confirm(`Remove '${series.name}' and all its watch history?`)) return
    await api.destroySeries(slug)
    navigate('/')
  }

  const handleRelocate = async () => {
    const newPath = await api.selectFolder()
    if (!newPath) return
    const result = await api.relocateSeries(slug, newPath)
    if (result?.error) {
      showToast(result.error, { type: 'error' })
    } else {
      showToast('Series relocated successfully', { type: 'success' })
      loadData()
    }
  }

  if (loading) return (
    <>
      <Navbar active="Episodes" />
      <div style={{ padding: '120px 48px', textAlign: 'center', color: 'var(--text-tertiary)' }}>Loading...</div>
    </>
  )

  if (!series) return null

  const hasMeta = series.poster_url || series.description
  const genres = genresList(series.genres)
  const year = premiereYear(series.premiered)
  const totalEps = series.total_episodes || 0
  const watchedCount = series.watched_episodes || 0
  const completePct = totalEps > 0 ? Math.round((watchedCount / totalEps) * 100) : 0
  const totalHours = series.total_watch_time > 0 ? (series.total_watch_time / 3600).toFixed(1) : null

  const ctaCardGlass = useGlassConfig('cta-card')
  const statChipGlass = useGlassConfig('stat-chip')
  const navBtnGlass = useGlassConfig('nav-btn')
  const playCtaGlass = useGlassConfig('play-cta')
  const primaryBtnGlass = useGlassConfig('primary-btn')

  // Determine last watched episode
  const lastWatched = [...episodes].filter(e => e.watched).sort((a, b) => {
    if (a.season_number !== b.season_number) return b.season_number - a.season_number
    return b.episode_number - a.episode_number
  })[0]

  // CTA logic
  const showResumeCta = resumeEp && (!nextEp || resumeEp.id !== nextEp.id)
  const allWatched = totalEps > 0 && watchedCount >= totalEps

  return (
    <>
      <Navbar
        active="Episodes"
        actions={canManage ? (
          <>
            <refractive.button className="topnav-btn" onClick={handleScan} refraction={navBtnGlass}>Rescan</refractive.button>
            <refractive.button className="topnav-btn" onClick={handleRefresh} refraction={navBtnGlass}>Refresh</refractive.button>
            <refractive.button className="topnav-btn" onClick={handleRelocate} refraction={navBtnGlass}>Relocate</refractive.button>
            <refractive.button className="topnav-btn topnav-btn--danger" onClick={handleRemove} refraction={navBtnGlass}>Remove</refractive.button>
          </>
        ) : null}
      />
      {hasNowPlaying && <NowPlaying />}

      {/* Hero */}
      {hasMeta && (
        <header
          className="show-hero"
          style={series.poster_url ? { '--poster': `url(${series.poster_url})` } : undefined}
        >
          <div className="show-hero-bg" />
          <div className="show-hero-content">
            {series.poster_url && (
              <div className="show-poster">
                <img src={series.poster_url} alt={series.name} />
              </div>
            )}
            <div className="show-info">
              <h1 className="show-title">{series.name}</h1>
              <div className="show-meta-row">
                {year && <span>{year}</span>}
                {series.status && (
                  <span className={`show-status show-status--${statusClass(series.status)}`}>
                    {series.status}
                  </span>
                )}
                {series.rating && <span className="show-rating">{'\u2605'} {series.rating}</span>}
                {series.imdb_id && (
                  <a
                    href={`https://www.imdb.com/title/${series.imdb_id}/`}
                    target="_blank"
                    rel="noreferrer"
                    className="show-imdb"
                    tabIndex={isTV ? -1 : 0}
                  >
                    IMDb
                  </a>
                )}
              </div>
              {genres.length > 0 && (
                <div className="show-genres">{genres.join('  \u00B7  ')}</div>
              )}
              {series.description && (
                <p className="show-description">{series.description}</p>
              )}
            </div>
          </div>
        </header>
      )}

      <main className="show-main">
        {seasons.length === 0 ? (
          <div className="empty-hero" style={{ padding: '60px 0' }}>
            <h2>No episodes found</h2>
            {canManage ? (
              <>
                <p>Scan the media folder to load episodes.</p>
                <refractive.button className="btn-primary" onClick={handleScan} refraction={primaryBtnGlass}>Scan Media Folder</refractive.button>
              </>
            ) : (
              <p>No episodes have been scanned yet.</p>
            )}
          </div>
        ) : (
          <>
            {/* Resume CTA */}
            {showResumeCta && (
              <refractive.div className="cta-card cta-resume" refraction={ctaCardGlass}>
                <div className="cta-content">
                  <span className="cta-label">Resume Where You Left Off</span>
                  <div className="cta-episode">
                    <span className="cta-code">{resumeEp.code}</span>
                    <span className="cta-ep-title">{resumeEp.title}</span>
                  </div>
                  <div className="cta-progress-row">
                    <div className="cta-progress-track">
                      <div className="cta-progress-fill" style={{ width: `${progressPercent(resumeEp.progress_seconds, resumeEp.duration_seconds)}%` }} />
                    </div>
                    <span className="cta-progress-text">
                      {formatTime(resumeEp.progress_seconds)} / {formatTime(resumeEp.duration_seconds)} ({progressPercent(resumeEp.progress_seconds, resumeEp.duration_seconds)}%)
                    </span>
                  </div>
                </div>
                {canPlay && (
                  <refractive.button ref={primaryCtaRef} className="btn-play-cta btn-play-cta--resume" disabled={launching} onClick={() => handlePlay(resumeEp.id)} refraction={playCtaGlass} tabIndex={0}>
                    {launching ? <><span className="btn-spinner" /> Loading...</> : <><PlaySvg /> Resume</>}
                  </refractive.button>
                )}
              </refractive.div>
            )}

            {/* Next Up / Start / All Caught Up */}
            {nextEp ? (
              <refractive.div className="cta-card" refraction={ctaCardGlass}>
                <div className="cta-content">
                  <span className="cta-label">Up Next</span>
                  <div className="cta-episode">
                    <span className="cta-code">{nextEp.code}</span>
                    <span className="cta-ep-title">{nextEp.title}</span>
                  </div>
                  {nextEp.description && (
                    <p className="cta-desc">{truncate(nextEp.description, 150)}</p>
                  )}
                </div>
                {canPlay && (
                  <refractive.button ref={showResumeCta ? undefined : primaryCtaRef} className="btn-play-cta" disabled={launching} onClick={() => handlePlay(nextEp.id)} refraction={playCtaGlass} tabIndex={0}>
                    {launching ? <><span className="btn-spinner" /> Loading...</> : <><PlaySvg /> {nextEp.progress_seconds > 0 && nextEp.duration_seconds > 0 && (nextEp.progress_seconds / nextEp.duration_seconds) < 0.9 ? 'Resume' : 'Play'}</>}
                  </refractive.button>
                )}
              </refractive.div>
            ) : !lastWatched ? (
              episodes.length > 0 && (
                <refractive.div className="cta-card" refraction={ctaCardGlass}>
                  <div className="cta-content">
                    <span className="cta-label">Start Watching</span>
                    <div className="cta-episode">
                      <span className="cta-code">{episodes[0].code}</span>
                      <span className="cta-ep-title">{episodes[0].title}</span>
                    </div>
                  </div>
                  {canPlay && (
                    <refractive.button ref={showResumeCta ? undefined : primaryCtaRef} className="btn-play-cta" disabled={launching} onClick={() => handlePlay(episodes[0].id)} refraction={playCtaGlass} tabIndex={0}>
                      {launching ? <><span className="btn-spinner" /> Loading...</> : <><PlaySvg /> Play</>}
                    </refractive.button>
                  )}
                </refractive.div>
              )
            ) : allWatched ? (
              <refractive.div className="cta-card" refraction={ctaCardGlass}>
                <div className="cta-content">
                  <span className="cta-label">All Caught Up</span>
                  <div className="cta-episode">
                    <span className="cta-ep-title">You've watched all {seasons.length} seasons</span>
                  </div>
                </div>
              </refractive.div>
            ) : null}

            {/* Stats */}
            <div className="stats-row">
              <refractive.div className="stat" refraction={statChipGlass}><span className="stat-val">{seasons.length}</span><span className="stat-lbl">Seasons</span></refractive.div>
              <refractive.div className="stat" refraction={statChipGlass}><span className="stat-val">{totalEps}</span><span className="stat-lbl">Episodes</span></refractive.div>
              <refractive.div className="stat" refraction={statChipGlass}><span className="stat-val">{watchedCount}</span><span className="stat-lbl">Watched</span></refractive.div>
              {totalEps > 0 && <refractive.div className="stat" refraction={statChipGlass}><span className="stat-val">{completePct}%</span><span className="stat-lbl">Complete</span></refractive.div>}
              {totalHours && <refractive.div className="stat" refraction={statChipGlass}><span className="stat-val">{totalHours}</span><span className="stat-lbl">Hours</span></refractive.div>}
            </div>

            {/* Season Tabs */}
            <SeasonTabs
              seasons={seasons}
              episodes={episodes}
              activeSeason={activeSeason}
              onSelect={setActiveSeason}
            />

            {/* Season Panels */}
            {seasons.map(num => {
              const seasonEps = episodes.filter(e => e.season_number === num)
              const watchedInSeason = seasonEps.filter(e => e.watched).length
              const pct = seasonEps.length > 0 ? Math.round((watchedInSeason / seasonEps.length) * 100) : 0

              // Season download stats
              const downloadedInSeason = seasonEps.filter(e => e.download && e.download.status === 'complete').length
              const hasAnyDownloads = downloadedInSeason > 0
              const allDownloaded = downloadedInSeason === seasonEps.length

              return (
                <section
                  key={num}
                  className={`season-panel${num === activeSeason ? ' active' : ''}`}
                >
                  <div className="season-header">
                    <h2>{num === 0 ? 'Specials' : `Season ${num}`}</h2>
                    <span className="season-detail">
                      {seasonEps.length} episodes &middot; {watchedInSeason} watched
                      {canDownload && hasAnyDownloads && (
                        <> &middot; {downloadedInSeason} downloaded</>
                      )}
                    </span>
                    {canDownload && (
                      <div className="season-header-actions">
                        {hasAnyDownloads ? (
                          <button
                            className="btn-season-dl btn-season-dl--delete"
                            onClick={() => handleDeleteSeasonDownloads(num)}
                            title="Delete season downloads"
                          >
                            {allDownloaded ? 'Delete All Downloads' : `Delete ${downloadedInSeason} Downloads`}
                          </button>
                        ) : (
                          <button
                            className="btn-season-dl"
                            onClick={() => handleDownloadSeason(num)}
                            title="Download entire season"
                          >
                            Download Season
                          </button>
                        )}
                      </div>
                    )}
                    <div className="season-bar">
                      <div className="season-bar-fill" style={{ width: `${pct}%` }} />
                    </div>
                  </div>
                  <div className="ep-list">
                    {seasonEps.map(ep => (
                      <EpisodeRow
                        key={ep.id}
                        episode={ep}
                        isCurrent={lastWatched?.id === ep.id}
                        onPlay={handlePlay}
                        onToggle={handleToggle}
                        onOpenInVlc={handleOpenInVlc}
                        onOpenInDefault={handleOpenInDefault}
                        onDownload={handleDownloadEpisode}
                        onDeleteDownload={handleDeleteDownloadEpisode}
                        vlcAvailable={vlcAvailable}
                        downloadProgress={downloadProgress[ep.id]}
                      />
                    ))}
                  </div>
                </section>
              )
            })}
          </>
        )}
      </main>
    </>
  )
}
