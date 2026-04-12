import { useRef, useEffect } from 'react'

// Detect Android TV
const isTV = typeof window !== 'undefined' && window.Capacitor?.isNativePlatform?.() === true

export default function SeasonTabs({ seasons, episodes, activeSeason, onSelect }) {
  const containerRef = useRef(null)
  const activeRef = useRef(null)

  useEffect(() => {
    if (activeRef.current && containerRef.current) {
      activeRef.current.scrollIntoView({
        behavior: 'smooth',
        block: 'nearest',
        inline: 'center',
      })
    }
  }, [activeSeason])

  const handleKeyDown = (e, num, idx) => {
    if (e.key === 'Enter') {
      e.preventDefault()
      onSelect(num)
    }
    // TV: Handle Up to go to CTA button above
    if (isTV && e.key === 'ArrowUp') {
      e.preventDefault()
      // Find the nearest .btn-play-cta above
      const ctaBtn = document.querySelector('.btn-play-cta')
      if (ctaBtn) {
        ctaBtn.focus()
      }
    }
    // TV: Handle Down to go to first episode
    if (isTV && e.key === 'ArrowDown') {
      e.preventDefault()
      // Find the first focusable episode row in the active season panel
      const activePanel = document.querySelector('.season-panel.active')
      if (activePanel) {
        const firstEpRow = activePanel.querySelector('.ep-row[tabindex="0"]')
        if (firstEpRow) {
          firstEpRow.focus()
        }
      }
    }
    // TV: Handle Left/Right to navigate between seasons
    if (isTV && e.key === 'ArrowLeft' && idx > 0) {
      e.preventDefault()
      const prevTab = containerRef.current?.querySelectorAll('.season-tab')[idx - 1]
      if (prevTab) {
        prevTab.focus()
      }
    }
    if (isTV && e.key === 'ArrowRight' && idx < seasons.length - 1) {
      e.preventDefault()
      const nextTab = containerRef.current?.querySelectorAll('.season-tab')[idx + 1]
      if (nextTab) {
        nextTab.focus()
      }
    }
  }

  return (
    <div className="season-tabs" ref={containerRef}>
      {seasons.map((num, idx) => {
        const seasonEps = episodes.filter(e => e.season_number === num)
        const watchedCount = seasonEps.filter(e => e.watched).length
        const pct = seasonEps.length > 0 ? Math.round((watchedCount / seasonEps.length) * 100) : 0
        const isActive = num === activeSeason

        return (
          <button
            key={num}
            ref={isActive ? activeRef : null}
            className={`season-tab${isActive ? ' active' : ''}`}
            onClick={() => onSelect(num)}
            onKeyDown={(e) => handleKeyDown(e, num, idx)}
            tabIndex={0}
          >
            {num === 0 ? 'Specials' : `Season ${num}`}
            {pct === 100 && <span className="season-check">{'\u2713'}</span>}
            {pct > 0 && pct < 100 && <span className="season-pct">{pct}%</span>}
          </button>
        )
      })}
    </div>
  )
}
