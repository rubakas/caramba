# Liquid Glass Design with @hashintel/refractive

## Status: Ready to Execute

Package already installed (`npm i @hashintel/refractive` completed).

---

## 1. Navbar (`src/components/Navbar.jsx`)

**Change:** Replace `<nav>` with `<refractive.nav>`, add import.

```jsx
// ADD import
import { refractive } from '@hashintel/refractive'

// REPLACE <nav className="topnav"> with:
<refractive.nav className="topnav" refraction={{ radius: 0, blur: 8, bezelWidth: 1 }}>
// ... children stay the same ...
</refractive.nav>
```

---

## 2. NowPlaying (`src/components/NowPlaying.jsx`)

**Change:** Wrap both `.now-playing-bar` divs with `refractive.div`.

```jsx
// ADD import
import { refractive } from '@hashintel/refractive'

// REPLACE all <div className="now-playing-bar"> with:
<refractive.div className="now-playing-bar" refraction={{ radius: 12, blur: 6, bezelWidth: 2 }}>
// ... children stay the same ...
</refractive.div>
```

There are TWO instances of `<div className="now-playing-bar">` in this file (in-app and VLC). Both should be replaced.

---

## 3. ToastContainer (`src/components/ToastContainer.jsx`)

**Change:** Wrap each toast `<div>` with `refractive.div`.

```jsx
// ADD import
import { refractive } from '@hashintel/refractive'

// REPLACE the inner toast <div> with:
<refractive.div
  key={toast.id}
  className={`toast toast--${toast.type}${toast.fading ? ' fade-out' : ''}`}
  onClick={() => dismiss(toast.id)}
  refraction={{ radius: 980, blur: 6, bezelWidth: 2 }}
>
  {/* children stay the same */}
</refractive.div>
```

---

## 4. PosterCard (`src/components/PosterCard.jsx`)

**Change:** Wrap the `.card-rating` span with `refractive.span`.

```jsx
// ADD import
import { refractive } from '@hashintel/refractive'

// REPLACE:
{rating ? <span className="card-rating">{rating}</span> : <span />}
// WITH:
{rating ? <refractive.span className="card-rating" refraction={{ radius: 8, blur: 4, bezelWidth: 1 }}>{rating}</refractive.span> : <span />}
```

---

## 5. EpisodeRow (`src/components/EpisodeRow.jsx`)

**Change:** Wrap the `.ep-popover` div with `refractive.div`.

```jsx
// ADD import
import { refractive } from '@hashintel/refractive'

// REPLACE:
<div ref={menuRef} className="ep-popover">
// WITH:
<refractive.div ref={menuRef} className="ep-popover" refraction={{ radius: 10, blur: 8, bezelWidth: 2 }}>
// ... children stay the same ...
</refractive.div>
```

---

## 6. SeriesShow (`src/pages/SeriesShow.jsx`)

**Change:** Wrap CTA cards and stat cards with `refractive.div`.

```jsx
// ADD import
import { refractive } from '@hashintel/refractive'

// REPLACE all <div className="cta-card ..."> with:
<refractive.div className="cta-card ..." refraction={{ radius: 16, blur: 4, bezelWidth: 2 }}>
// (match existing className including cta-resume variant)

// REPLACE each <div className="stat"> with:
<refractive.div className="stat" refraction={{ radius: 12, blur: 4, bezelWidth: 1 }}>
```

There are 4 CTA card instances and 5 stat items. All should use refractive.div.

---

## 7. Discover Modal (`src/pages/Discover.jsx`)

**Change:** Wrap modal container and close button.

```jsx
// ADD import
import { refractive } from '@hashintel/refractive'

// In DetailModal component:
// REPLACE <div className="dm-container"> with:
<refractive.div className="dm-container" refraction={{ radius: 16, blur: 6, bezelWidth: 2 }}>

// REPLACE <button className="dm-close" ...> with:
<refractive.button className="dm-close" onClick={onClose} refraction={{ radius: 18, blur: 4, bezelWidth: 1 }}>
```

---

## 8. UpdatePrompt (`src/components/UpdatePrompt.jsx`)

**Change:** Wrap the `.update-prompt` div with `refractive.div`.

```jsx
// ADD import
import { refractive } from '@hashintel/refractive'

// REPLACE <div className="update-prompt"> with:
<refractive.div className="update-prompt" refraction={{ radius: 16, blur: 6, bezelWidth: 2 }}>
```

---

## 9. CSS Updates (`src/styles/app.css`)

### Navbar (.topnav)
```css
/* REPLACE */
background: rgba(0,0,0,.72);
backdrop-filter: saturate(180%) blur(20px);
-webkit-backdrop-filter: saturate(180%) blur(20px);

/* WITH */
background: rgba(0,0,0,.35);
```

### Toast (.toast)
```css
/* REPLACE */
backdrop-filter: blur(20px);
-webkit-backdrop-filter: blur(20px);

/* WITH (remove both lines — refractive handles it) */
```

### NowPlaying (.now-playing-bar)
```css
/* REPLACE */
background: rgba(48,209,88,.08);

/* WITH */
background: rgba(48,209,88,.05);
```

### Card Rating (.card-rating)
```css
/* REPLACE */
background: rgba(0,0,0,.6);
backdrop-filter: blur(10px);
-webkit-backdrop-filter: blur(10px);

/* WITH */
background: rgba(0,0,0,.3);
```

### Episode Popover (.ep-popover)
```css
/* REPLACE */
background: rgba(28, 28, 30, 0.95);
backdrop-filter: blur(20px);
-webkit-backdrop-filter: blur(20px);

/* WITH */
background: rgba(28, 28, 30, 0.45);
```

### CTA Card (.cta-card)
```css
/* REPLACE */
background: var(--surface);

/* WITH */
background: rgba(28, 28, 30, 0.4);
```

### CTA Resume (.cta-resume)
```css
/* REPLACE */
background: rgba(255,159,10,.04);

/* WITH */
background: rgba(255,159,10,.03);
```

### Stat (.stat)
```css
/* REPLACE */
background: var(--surface);

/* WITH */
background: rgba(28, 28, 30, 0.4);
```

### Discover Modal (.dm-container)
```css
/* REPLACE */
background: var(--bg);

/* WITH */
background: rgba(0, 0, 0, 0.6);
```

### Modal Close (.dm-close)
```css
/* REPLACE */
background: rgba(0, 0, 0, .5);
backdrop-filter: blur(8px);

/* WITH */
background: rgba(0, 0, 0, .25);
```

### Video Player Track Popover (.video-player-track-popover)
```css
/* REPLACE */
background: rgba(28, 28, 30, 0.95);
backdrop-filter: blur(20px);
-webkit-backdrop-filter: blur(20px);

/* WITH */
background: rgba(28, 28, 30, 0.45);
```

### Update Prompt (.update-prompt)
```css
/* REPLACE */
background: var(--surface-elevated);
backdrop-filter: blur(20px);
-webkit-backdrop-filter: blur(20px);

/* WITH */
background: rgba(44, 44, 46, 0.4);
```

### Discover Watchlist Button (.discover-watchlist-btn)
```css
/* REPLACE */
backdrop-filter: blur(8px);

/* WITH (remove line — refractive handles it) */
```

---

## 10. Verify

Run `npm run build` to check for errors.
