import { useState, useEffect, useMemo, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import Navbar from '../components/Navbar'
import { useApi } from '../context/ApiContext'

const PROMPT_TEMPLATE = `I'm building English-as-a-second-language lessons from an episode's subtitle file.
From the SRT below, pick 10-20 conversational phrases that are useful for an
intermediate Ukrainian learner of English. Prefer phrases that:
- show idioms, phrasal verbs, common collocations, or culturally interesting expressions
- span roughly 1-5 seconds of speech (so they make a good short clip)
- are spaced through the episode (not all from the same scene)

For each phrase, return:
  - phrase:      the original English text (as spoken)
  - translation: a natural Ukrainian translation
  - meaning:     a short note (1-2 sentences) explaining the idiom/grammar/cultural reference
  - startMs:     start time in milliseconds (from the SRT cue, NOT seconds)
  - endMs:       end time in milliseconds

Return ONLY a JSON object, no preamble or commentary, in this exact shape:

{
  "phrases": [
    {
      "phrase": "...",
      "translation": "...",
      "meaning": "...",
      "startMs": 12345,
      "endMs": 14567
    }
  ]
}

Subtitle file follows:

`

export default function LessonNew() {
  const { episodeId } = useParams()
  const api = useApi()
  const navigate = useNavigate()

  const [episode, setEpisode] = useState(null)
  const [srt, setSrt] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [jsonText, setJsonText] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    let cancelled = false
    async function load() {
      try {
        const list = await api.listLearningEpisodes()
        const found = (list || []).find((e) => String(e.id) === String(episodeId))
        if (!found) {
          if (!cancelled) setError('Episode not found in the learning queue.')
          return
        }
        if (cancelled) return
        setEpisode(found)
        if (found.subtitle?.id) {
          const sub = await api.getSubtitle(found.subtitle.id)
          if (cancelled) return
          setSrt(sub?.content || '')
        } else {
          setError('No extracted subtitle yet — go back and click Prepare lesson first.')
        }
      } catch (err) {
        if (!cancelled) setError(err.message || 'Failed to load')
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    load()
    return () => { cancelled = true }
  }, [api, episodeId])

  const promptText = useMemo(() => `${PROMPT_TEMPLATE}${srt}`, [srt])

  const handleCopy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(promptText)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch (err) {
      setError('Clipboard access denied — select all and copy manually.')
    }
  }, [promptText])

  const handleCreate = useCallback(async () => {
    setError(null)
    setSubmitting(true)
    try {
      let parsed
      try {
        parsed = JSON.parse(jsonText)
      } catch {
        throw new Error('Pasted text is not valid JSON.')
      }
      if (!Array.isArray(parsed?.phrases) || parsed.phrases.length === 0) {
        throw new Error('JSON must include a non-empty "phrases" array.')
      }
      const lesson = await api.createLesson({
        episodeId: Number(episodeId),
        phrases: parsed.phrases,
        provider: 'manual'
      })
      navigate(`/learn/lessons/${lesson.id}`)
    } catch (err) {
      setError(err.message || 'Failed to create lesson')
    } finally {
      setSubmitting(false)
    }
  }, [api, jsonText, episodeId, navigate])

  return (
    <>
      <Navbar active="Learn" />
      <main className="add-main">
        <div className="add-container" style={{ maxWidth: 960 }}>
          <h1 className="page-title">New lesson</h1>
          {episode && (
            <p className="add-help" style={{ marginBottom: 24 }}>
              {episode.showName} · {episode.code}
              {episode.title ? ` · ${episode.title}` : ''}
            </p>
          )}

          {error && <div className="alert" style={{ marginBottom: 16 }}>{error}</div>}

          {loading ? (
            <p className="add-help">Loading…</p>
          ) : (
            <>
              <section style={{ marginBottom: 32 }}>
                <h2 style={{ fontSize: 18, marginBottom: 8 }}>1. Copy this prompt</h2>
                <p className="add-help" style={{ marginBottom: 12 }}>
                  Paste it into <a href="https://claude.ai/" target="_blank" rel="noreferrer">claude.ai</a> (or any LLM). The SRT is already inlined.
                </p>
                <textarea
                  readOnly
                  value={promptText}
                  rows={12}
                  style={textareaStyle}
                />
                <button type="button" className="topnav-btn" onClick={handleCopy} style={{ marginTop: 8 }}>
                  {copied ? 'Copied!' : 'Copy to clipboard'}
                </button>
              </section>

              <section style={{ marginBottom: 32 }}>
                <h2 style={{ fontSize: 18, marginBottom: 8 }}>2. Paste the JSON it returns</h2>
                <p className="add-help" style={{ marginBottom: 12 }}>
                  The LLM should reply with a JSON object containing a <code>phrases</code> array. Paste it here:
                </p>
                <textarea
                  value={jsonText}
                  onChange={(e) => setJsonText(e.target.value)}
                  placeholder='{"phrases": [{"phrase": "...", "translation": "...", "meaning": "...", "startMs": 1000, "endMs": 2500}]}'
                  rows={12}
                  style={textareaStyle}
                />
              </section>

              <button
                type="button"
                className="btn-choose-folder"
                onClick={handleCreate}
                disabled={submitting || !jsonText.trim()}
                style={{ padding: '10px 20px' }}
              >
                {submitting ? 'Creating…' : 'Create lesson'}
              </button>
            </>
          )}
        </div>
      </main>
    </>
  )
}

const textareaStyle = {
  width: '100%',
  background: 'rgba(0, 0, 0, 0.3)',
  border: '1px solid rgba(255, 255, 255, 0.12)',
  borderRadius: 8,
  padding: 12,
  color: 'inherit',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
  fontSize: 13,
  lineHeight: 1.5,
  resize: 'vertical'
}
