function resolveTarget(envValue) {
  const t = envValue || ''
  if (!t) return { kind: 'auto' }
  if (t.startsWith('file:')) return { kind: 'file', filePath: t.slice(5) }
  if (t.startsWith('episode:')) return { kind: 'episode', id: t.slice(8) }
  if (t.startsWith('show:')) return { kind: 'show', slug: t.slice(5) }
  if (t.startsWith('movie:')) return { kind: 'movie', slug: t.slice(6) }
  if (t.startsWith('slug:')) return { kind: 'slug', slug: t.slice(5) }
  if (t.startsWith('/')) return { kind: 'file', filePath: t }
  return { kind: 'slug', slug: t }
}

module.exports = { resolveTarget }
