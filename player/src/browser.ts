/**
 * Minimal UA-based browser detection. Used by mse-workarounds.ts to apply
 * browser-specific HLS.js config and event handling.
 *
 * Intentionally conservative — false-negatives are safe (we skip a workaround
 * that wouldn't have helped) but false-positives can corrupt other browsers.
 */
export interface BrowserInfo {
  name: 'firefox' | 'chromium-edge' | 'legacy-edge' | 'chrome' | 'safari' | 'other';
  version: number | null;
  isFirefox: boolean;
  isEdge: boolean;
  isChrome: boolean;
  isSafari: boolean;
  isMobile: boolean;
}

export function detectBrowser(ua: string = typeof navigator === 'undefined' ? '' : navigator.userAgent): BrowserInfo {
  const isMobile = /Mobile|Android|iPhone|iPad/i.test(ua);

  // Order matters — Edge contains "Chrome", so check Edge first.
  let legacy = /Edge\/(\d+)/.exec(ua);
  if (legacy) {
    return { name: 'legacy-edge', version: Number(legacy[1]),
             isFirefox: false, isEdge: true, isChrome: false, isSafari: false, isMobile };
  }
  let chromiumEdge = /Edg\/(\d+)/.exec(ua);
  if (chromiumEdge) {
    return { name: 'chromium-edge', version: Number(chromiumEdge[1]),
             isFirefox: false, isEdge: true, isChrome: false, isSafari: false, isMobile };
  }
  let firefox = /Firefox\/(\d+)/.exec(ua);
  if (firefox) {
    return { name: 'firefox', version: Number(firefox[1]),
             isFirefox: true, isEdge: false, isChrome: false, isSafari: false, isMobile };
  }
  let chrome = /Chrome\/(\d+)/.exec(ua);
  if (chrome) {
    return { name: 'chrome', version: Number(chrome[1]),
             isFirefox: false, isEdge: false, isChrome: true, isSafari: false, isMobile };
  }
  let safari = /Version\/(\d+).*Safari/.exec(ua);
  if (safari) {
    return { name: 'safari', version: Number(safari[1]),
             isFirefox: false, isEdge: false, isChrome: false, isSafari: true, isMobile };
  }
  return { name: 'other', version: null,
           isFirefox: false, isEdge: false, isChrome: false, isSafari: false, isMobile };
}
