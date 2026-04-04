import { useState, useEffect, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { refractive } from '@hashintel/refractive'
import Navbar from '../components/Navbar'
import NowPlaying from '../components/NowPlaying'
import SeasonTabs from '../components/SeasonTabs'
import EpisodeRow from '../components/EpisodeRow'
import { usePlayer } from '../context/PlayerContext'
import { useToast } from '../context/ToastContext'
import { genresList, premiereYear, statusClass, formatTime, progressPercent, truncate } from '../utils'

const PlaySvg = ({ size = 20 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
)

export default function SeriesShow() {
  const { slug } = useParams()
  const navigate = useNavigate()
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

  const loadData = useCallback(async () => {
    try {
      const [s, eps, seasonNums, resume, next, hasVlc] = await Promise.all([
        window.api.getSeries(slug),
        window.api.getSeriesEpisodes(slug),
        window.api.getSeriesSeasons(slug),
        window.api.getResumable(slug),
        window.api.getNextUp(slug),
        window.api.checkVlc(),
      ])
      if (!s) { navigate('/'); return }
      setSeries(s)
      setEpisodes(eps)
      setSeasons(seasonNums)
      setResumeEp(resume)
      setNextEp(next)
      setVlcAvailable(hasVlc)

      // Determine active season: last watched episode's season, or first season
      if (activeSeason === null) {
        const lastWatched = [...eps].filter(e => e.watched).sort((a, b) => {
          if (a.season_number !== b.season_number) return b.season_number - a.season_number
          return b.episode_number - a.episode_number
        })[0]
        setActiveSeason(lastWatched?.season_number ?? seasonNums[0] ?? 1)
      }
    } catch (err) {
      console.error('Failed to load series:', err)
    } finally {
      setLoading(false)
    }
  }, [slug, navigate, activeSeason])

  useEffect(() => {
    loadData()
    const handleStop = () => loadData()
    window.addEventListener('playback-stopped', handleStop)
    const unsubVlc = window.api.onVlcPlaybackEnded(() => loadData())
    return () => {
      window.removeEventListener('playback-stopped', handleStop)
      unsubVlc()
    }
  }, [loadData])

  const handlePlay = async (episodeId) => {
    const result = await window.api.playEpisode(episodeId)
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
    await window.api.toggleEpisode(episodeId)
    loadData()
  }

  const handleOpenInVlc = async (episodeId) => {
    const ep = episodes.find(e => e.id === episodeId)
    if (!ep?.file_path) return
    const result = await window.api.openInVlc({ filePath: ep.file_path, episodeId })
    if (result?.error) showToast(result.error, { type: 'error' })
  }

  const handleOpenInDefault = async (episodeId) => {
    const ep = episodes.find(e => e.id === episodeId)
    if (!ep?.file_path) return
    const result = await window.api.openInDefault(ep.file_path)
    if (result?.error) showToast(result.error, { type: 'error' })
  }

  const handleScan = async () => {
    await window.api.scanSeries(slug)
    loadData()
  }

  const handleRefresh = async () => {
    await window.api.refreshSeriesMetadata(slug)
    loadData()
  }

  const handleRemove = async () => {
    if (!confirm(`Remove '${series.name}' and all its watch history?`)) return
    await window.api.destroySeries(slug)
    navigate('/')
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
        actions={
          <>
            <button className="topnav-btn" onClick={handleScan}>Rescan</button>
            <button className="topnav-btn" onClick={handleRefresh}>Refresh</button>
            <button className="topnav-btn topnav-btn--danger" onClick={handleRemove}>Remove</button>
          </>
        }
      />
      <NowPlaying />

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
            <p>Scan the media folder to load episodes.</p>
            <button className="btn-primary" onClick={handleScan}>Scan Media Folder</button>
          </div>
        ) : (
          <>
            {/* Resume CTA */}
            {showResumeCta && (
              <refractive.div className="cta-card cta-resume" refraction={{ radius: 16, blur: 4, bezelWidth: 2 }}>
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
                <button className="btn-play-cta btn-play-cta--resume" disabled={launching} onClick={() => handlePlay(resumeEp.id)}>
                  {launching ? <><span className="btn-spinner" /> Loading...</> : <><PlaySvg /> Resume</>}
                </button>
              </refractive.div>
            )}

            {/* Next Up / Start / All Caught Up */}
            {nextEp ? (
              <refractive.div className="cta-card" refraction={{ radius: 16, blur: 4, bezelWidth: 2 }}>
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
                <button className="btn-play-cta" disabled={launching} onClick={() => handlePlay(nextEp.id)}>
                  {launching ? <><span className="btn-spinner" /> Loading...</> : <><PlaySvg /> {nextEp.progress_seconds > 0 && nextEp.duration_seconds > 0 && (nextEp.progress_seconds / nextEp.duration_seconds) < 0.9 ? 'Resume' : 'Play'}</>}
                </button>
              </refractive.div>
            ) : !lastWatched ? (
              episodes.length > 0 && (
                <refractive.div className="cta-card" refraction={{ radius: 16, blur: 4, bezelWidth: 2 }}>
                  <div className="cta-content">
                    <span className="cta-label">Start Watching</span>
                    <div className="cta-episode">
                      <span className="cta-code">{episodes[0].code}</span>
                      <span className="cta-ep-title">{episodes[0].title}</span>
                    </div>
                  </div>
                  <button className="btn-play-cta" disabled={launching} onClick={() => handlePlay(episodes[0].id)}>
                    {launching ? <><span className="btn-spinner" /> Loading...</> : <><PlaySvg /> Play</>}
                  </button>
                </refractive.div>
              )
            ) : allWatched ? (
              <refractive.div className="cta-card" refraction={{ radius: 16, blur: 4, bezelWidth: 2 }}>
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
              <refractive.div className="stat" refraction={{ radius: 12, blur: 4, bezelWidth: 1 }}><span className="stat-val">{seasons.length}</span><span className="stat-lbl">Seasons</span></refractive.div>
              <refractive.div className="stat" refraction={{ radius: 12, blur: 4, bezelWidth: 1 }}><span className="stat-val">{totalEps}</span><span className="stat-lbl">Episodes</span></refractive.div>
              <refractive.div className="stat" refraction={{ radius: 12, blur: 4, bezelWidth: 1 }}><span className="stat-val">{watchedCount}</span><span className="stat-lbl">Watched</span></refractive.div>
              {totalEps > 0 && <refractive.div className="stat" refraction={{ radius: 12, blur: 4, bezelWidth: 1 }}><span className="stat-val">{completePct}%</span><span className="stat-lbl">Complete</span></refractive.div>}
              {totalHours && <refractive.div className="stat" refraction={{ radius: 12, blur: 4, bezelWidth: 1 }}><span className="stat-val">{totalHours}</span><span className="stat-lbl">Hours</span></refractive.div>}
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

              return (
                <section
                  key={num}
                  className={`season-panel${num === activeSeason ? ' active' : ''}`}
                >
                  <div className="season-header">
                    <h2>{num === 0 ? 'Specials' : `Season ${num}`}</h2>
                    <span className="season-detail">
                      {seasonEps.length} episodes &middot; {watchedInSeason} watched
                    </span>
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
                        vlcAvailable={vlcAvailable}
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
