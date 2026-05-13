/**
 * Host-implemented callback bundle for playback lifecycle reporting.
 * Defaults to a fire-and-forget POST to `reporterUrl` if supplied.
 */
export interface ReporterState {
  currentTime: number;
  duration: number;
  paused: boolean;
  rate: number;
  volume: number;
  muted: boolean;
}

export interface Reporter {
  onStart?(state: ReporterState): void;
  onProgress?(state: ReporterState): void;
  onStop?(state: ReporterState): void;
  onError?(error: { message: string; code?: number }, state: ReporterState): void;
}

export function httpReporter(reporterUrl: string, opts: { intervalMs?: number } = {}): Reporter {
  const interval = opts.intervalMs ?? 10_000;
  let lastSent = 0;

  const post = (kind: string, state: ReporterState) => {
    try {
      const body = JSON.stringify({ kind, ...state });
      // Use sendBeacon when available so stop events survive page unload.
      if (kind === 'stop' && 'sendBeacon' in navigator) {
        navigator.sendBeacon(reporterUrl, body);
        return;
      }
      fetch(reporterUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body,
        keepalive: true
      }).catch(() => {});
    } catch {
      // Reporter must never break playback.
    }
  };

  return {
    onStart: (s) => post('start', s),
    onProgress: (s) => {
      const now = Date.now();
      if (now - lastSent < interval) return;
      lastSent = now;
      post('progress', s);
    },
    onStop: (s) => post('stop', s),
    onError: (e, s) => post('error', { ...s, errorMessage: e.message } as ReporterState)
  };
}
