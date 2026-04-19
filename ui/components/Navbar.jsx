import { useNavigate, useLocation } from 'react-router-dom'
import { refractive } from '../config/refractive'
import { useGlassConfig } from '../config/useGlassConfig'
import { useCapabilities } from '../context/ApiContext'

const PlayIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
)

// Detect Android TV
const isTV = typeof window !== 'undefined' && window.Capacitor?.isNativePlatform?.() === true

export default function Navbar({ active, actions, rightContent }) {
  const navigate = useNavigate()
  const location = useLocation()
  const navbarGlass = useGlassConfig('navbar')
  const { hasSettings, hasPlayground, canAdmin } = useCapabilities()

  const links = [
    { label: 'Shows', path: '/' },
    { label: 'Movies', path: '/movies' },
    ...(canAdmin ? [{ label: 'Admin', path: '/admin' }] : []),
    ...(hasSettings ? [{ label: 'Settings', path: '/settings' }] : []),
    ...(import.meta.env.DEV && hasPlayground ? [{ label: 'Playground', path: '/playground' }] : []),
  ]

  return (
    <refractive.nav
      className="topnav"
      refraction={navbarGlass}
    >
      <a className="topnav-brand" onClick={() => navigate('/')} style={{ cursor: 'pointer' }} tabIndex={isTV ? -1 : undefined}>
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
