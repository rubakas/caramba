import { useNavigate, useLocation } from 'react-router-dom'

const PlayIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
)

export default function Navbar({ active, actions, rightContent }) {
  const navigate = useNavigate()
  const location = useLocation()

  const links = [
    { label: 'Library', path: '/' },
    { label: 'Movies', path: '/movies' },
    { label: 'History', path: '/history' },
    { label: 'Settings', path: '/settings' },
  ]

  return (
    <nav className="topnav">
      <a className="topnav-brand" onClick={() => navigate('/')} style={{ cursor: 'pointer' }}>
        Caramba
      </a>
      <div className="topnav-links">
        {links.map(link => (
          <a
            key={link.path}
            className={`topnav-link${active === link.label ? ' active' : ''}`}
            onClick={() => navigate(link.path)}
          >
            {link.label}
          </a>
        ))}
      </div>
      {rightContent}
      {actions && (
        <div className="topnav-actions">
          {actions}
        </div>
      )}
    </nav>
  )
}
