import { useNavigate, useLocation } from 'react-router-dom'
import { refractive } from '../config/refractive'
import { useGlassConfig } from '../config/useGlassConfig'
import { useCapabilities } from '../context/ApiContext'

const PlayIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
)

export default function Navbar({ active, actions, rightContent }) {
  const navigate = useNavigate()
  const location = useLocation()
  const navbarGlass = useGlassConfig('navbar')
  const { hasSettings } = useCapabilities()

  const links = [
    { label: 'Library', path: '/' },
    { label: 'Movies', path: '/movies' },
    { label: 'Discover', path: '/discover' },
    { label: 'History', path: '/history' },
    ...(hasSettings ? [{ label: 'Settings', path: '/settings' }] : []),
    ...(import.meta.env.DEV && hasSettings ? [{ label: 'Playground', path: '/playground' }] : []),
  ]

  return (
    <refractive.nav
      className="topnav"
      refraction={navbarGlass}
    >
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
    </refractive.nav>
  )
}
