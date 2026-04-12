import { useRef, useEffect } from 'react'

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

  return (
    <div className="season-tabs" ref={containerRef}>
      {seasons.map(num => {
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
