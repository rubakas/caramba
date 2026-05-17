import { describe, it, expect } from 'vitest'
import { runtimeDisplay, formatTime, progressPercent } from './utils.js'

describe('runtimeDisplay', () => {
  // The Rails server stores `runtime` in MINUTES (see CLAUDE.md /
  // imdb_api_service.rb:44 / tvmaze_service.rb:196). Until 2026-05-17 this
  // formatter mistakenly divided by 60 again, so a 124-minute movie rendered
  // as "2m" instead of "2h 4m". Regression test for that bug.
  it('treats input as minutes, not seconds', () => {
    expect(runtimeDisplay(124)).toBe('2h 4m')
    expect(runtimeDisplay(120)).toBe('2h')
    expect(runtimeDisplay(45)).toBe('45m')
    expect(runtimeDisplay(60)).toBe('1h')
    expect(runtimeDisplay(90)).toBe('1h 30m')
  })

  it('returns null for falsy input', () => {
    expect(runtimeDisplay(null)).toBeNull()
    expect(runtimeDisplay(undefined)).toBeNull()
    expect(runtimeDisplay(0)).toBeNull()
  })
})

describe('formatTime', () => {
  it('formats seconds as m:ss', () => {
    expect(formatTime(65)).toBe('1:05')
  })

  it('formats seconds as h:mm:ss when >= 1 hour', () => {
    expect(formatTime(3725)).toBe('1:02:05')
  })

  it('returns 0:00 for falsy / non-positive input', () => {
    expect(formatTime(0)).toBe('0:00')
    expect(formatTime(null)).toBe('0:00')
  })
})

describe('progressPercent', () => {
  it('clamps to 100 and rounds', () => {
    expect(progressPercent(50, 100)).toBe(50)
    expect(progressPercent(99, 100)).toBe(99)
    expect(progressPercent(200, 100)).toBe(100)
  })

  it('returns 0 for missing values', () => {
    expect(progressPercent(0, 100)).toBe(0)
    expect(progressPercent(50, 0)).toBe(0)
  })
})
