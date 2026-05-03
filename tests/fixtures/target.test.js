const { test, expect } = require('@playwright/test')
const { resolveTarget } = require('./target')

test('resolveTarget — empty env returns auto', () => {
  expect(resolveTarget(undefined)).toEqual({ kind: 'auto' })
  expect(resolveTarget('')).toEqual({ kind: 'auto' })
})

test('resolveTarget — file: prefix', () => {
  expect(resolveTarget('file:/tmp/foo.mkv')).toEqual({ kind: 'file', filePath: '/tmp/foo.mkv' })
})

test('resolveTarget — episode: prefix', () => {
  expect(resolveTarget('episode:42')).toEqual({ kind: 'episode', id: '42' })
})

test('resolveTarget — slug: prefix', () => {
  expect(resolveTarget('slug:dune-2021')).toEqual({ kind: 'slug', slug: 'dune-2021' })
})

test('resolveTarget — bare absolute path → file', () => {
  expect(resolveTarget('/Users/x/Movies/Dune.mkv')).toEqual({ kind: 'file', filePath: '/Users/x/Movies/Dune.mkv' })
})

test('resolveTarget — bare slug', () => {
  expect(resolveTarget('inception')).toEqual({ kind: 'slug', slug: 'inception' })
})
