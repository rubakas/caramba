/**
 * Caramba's original subtitle size + appearance presets, lifted intact from
 * the pre-port Caramba VideoPlayer (commit a5ad2da, `ui/components/VideoPlayer.jsx`).
 * Kept here in the player package so the host doesn't need to redefine them
 * and the look stays consistent if the renderer evolves.
 *
 * The CSS strings below target the native WebVTT `::cue` pseudo-element. They
 * are unchanged from the original: any tweak should be made by the host via
 * its own `<style>` injection, not by editing these. Don't add `!important`;
 * the original CSS works because `::cue` user rules already beat the UA
 * defaults — `!important` here started cascading into unrelated cue styles
 * during track switches.
 */
export interface SubtitleSizePreset {
  id: 'small' | 'medium' | 'large';
  label: string;
  em: string;
}

export interface SubtitleStylePreset {
  id: 'classic' | 'outline' | 'drop-shadow' | 'transparent';
  label: string;
  css: string;
}

export const SUB_SIZES: SubtitleSizePreset[] = [
  { id: 'small',  label: 'S',  em: '1.4em' },
  { id: 'medium', label: 'M',  em: '1.9em' },
  { id: 'large',  label: 'L',  em: '2.6em' },
];

export const SUB_STYLES: SubtitleStylePreset[] = [
  { id: 'classic',     label: 'Classic',     css: 'background: rgba(0,0,0,0.75); color: #fff; text-shadow: none;' },
  { id: 'outline',     label: 'Outline',     css: 'background: transparent; color: #fff; text-shadow: -1px -1px 0 #000, 1px -1px 0 #000, -1px 1px 0 #000, 1px 1px 0 #000, 0 0 4px #000;' },
  { id: 'drop-shadow', label: 'Drop Shadow', css: 'background: transparent; color: #fff; text-shadow: 2px 2px 4px rgba(0,0,0,0.9), 0 0 8px rgba(0,0,0,0.6);' },
  { id: 'transparent', label: 'Transparent', css: 'background: rgba(0,0,0,0.4); color: #fff; text-shadow: none;' },
];

/**
 * The class added to the player's `<video>` element. Hosts target subtitle
 * CSS at `.${VIDEO_CLASS}::cue` so the selector beats UA defaults without
 * needing `!important` and without bleeding into other videos on the page.
 */
export const VIDEO_CLASS = 'jellyfin-player-video';

/**
 * Builds the `<style>` CSS body that applies one of the presets to the
 * player's video element. The original Caramba pre-port code lived inline
 * in VideoPlayer.jsx; lifting it here keeps the renderer and the styling
 * in lockstep.
 *
 *   buildCueCss({ sizeId: 'medium', styleId: 'classic' })
 *   //=> ".jellyfin-player-video::cue { font-size: 1.9em; ... }"
 */
export function buildCueCss({
  sizeId,
  styleId,
}: {
  sizeId?: SubtitleSizePreset['id'];
  styleId?: SubtitleStylePreset['id'];
}): string {
  const size  = SUB_SIZES.find((s) => s.id === sizeId)  ?? SUB_SIZES[1];
  const style = SUB_STYLES.find((s) => s.id === styleId) ?? SUB_STYLES[0];
  return `.${VIDEO_CLASS}::cue { font-size: ${size.em}; font-family: inherit; ${style.css} }`;
}
