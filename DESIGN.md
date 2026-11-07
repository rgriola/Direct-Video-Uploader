---
version: alpha
name: Fixer — Clean Editorial
description: >
  Shared design tokens for the Fixer web surfaces — the Admin Dashboard
  (admin/) and the server-rendered Clip Viewer (server/src/routes/clips.js).
  This file is the single normative source for color, radius, and type
  values. The machine-readable tokens below are implemented verbatim in
  admin/public/tokens.css, which both apps load so there is exactly one
  place to change a value.
omitted:
  - section: Elevation & Depth
    reason: "No shadow/elevation scale is standardized yet; ad hoc box-shadows remain per-component until a scale is proposed."
colors:
  background: "#ffffff"
  foreground: "#111111"
  card: "#ffffff"
  card-foreground: "#111111"
  card-hover: "#f3f1ed"
  secondary: "#ffffff"
  secondary-foreground: "#111111"
  secondary-dark-shade: "#352e5d"
  muted-foreground: "#4b5563"
  border: "#d4d0e8"
  border-subtle: "#e8e5f0"
  border-blue: "#4a9eff"
  border-green: "#47c6a7"
  border-purple: "#8576ee"
  border-amber: "#f4d247"
  accent: "#8576ee"
  accent-foreground: "#ffffff"
  accent-blue: "#4a9eff"
  accent-green: "#47c6a7"
  accent-amber: "#f4d247"
  accent-red: "#ea3343"
  accent-purple: "#8576ee"
  accent-blue-glow: "#4a9eff18"
  accent-green-glow: "#47c6a718"
  accent-amber-glow: "#f4d24718"
  accent-red-glow: "#ea334318"
  accent-purple-glow: "#8576ee18"
  ring: "#8576ee"
typography:
  font-sans:
    fontFamily: Outfit
  font-mono:
    fontFamily: JetBrains Mono
  text-xs:
    fontFamily: Outfit
    fontSize: 12px
  text-sm:
    fontFamily: Outfit
    fontSize: 14px
  text-base:
    fontFamily: Outfit
    fontSize: 16px
  text-lg:
    fontFamily: Outfit
    fontSize: 18px
  text-xl:
    fontFamily: Outfit
    fontSize: 20px
  text-2xl:
    fontFamily: Outfit
    fontSize: 24px
rounded:
  sm: 4px
  md: 6px
  lg: 8px
  xl: 12px
  2xl: 16px
  full: 9999px
components:
  card:
    backgroundColor: "{colors.card}"
    textColor: "{colors.card-foreground}"
    rounded: "{rounded.xl}"
    border: "{colors.border-subtle}"
  button-primary:
    backgroundColor: "{colors.accent-blue}"
    textColor: "{colors.accent-foreground}"
    rounded: "{rounded.lg}"
  button-icon:
    textColor: "{colors.muted-foreground}"
    rounded: "{rounded.md}"
  badge:
    backgroundColor: "{colors.accent-blue-glow}"
    textColor: "{colors.accent-blue}"
    rounded: "{rounded.md}"
    typography: "{typography.text-xs}"
---

## Overview

"Clean Editorial" — a warm, off-white dashboard with a single purple accent
family for interaction, and a small set of semantic status colors (blue,
green, amber, red, purple) reused for badges, pills, borders, and glow
backgrounds. The same tokens drive both the React Admin Dashboard and the
server-rendered Clip Viewer page, so a clip opened from Slack should feel
like the same product as the dashboard it links back to — not a different
app with a different theme.

Previously, this palette existed six times: four alternate "theme-*.css"
files (only one ever imported), a dead `index.css`, and a hand-copied
`:root` block inside the server's HTML template that had drifted to match
a *different, unused* theme file. That drift is why the Clip Viewer
rendered a dark/purple page while the Dashboard rendered light/white. This
spec exists so that never happens silently again — `admin/public/tokens.css`
is the only file that should ever declare these values.

## Colors

The palette is rooted in a near-white page background with a single purple
(`#8576ee`) used consistently for the primary brand accent, borders, and
focus rings. Five semantic accents (blue, green, amber, red, purple) carry
status meaning — e.g. online/ready = green, error = red, pending = amber —
and each has a matching low-opacity "glow" variant (`-glow` suffix) used as
a badge background so the solid color can be used as the badge's text
color without harming contrast.

- **Background / Card (`#ffffff`):** Page and card surfaces are the same
  off-white; cards are differentiated by `border-subtle` only, not a shadow.
- **Foreground (`#111111`):** Primary text. Never pure black, for a softer
  editorial feel.
- **Muted foreground (`#4b5563`):** Secondary/meta text (timestamps,
  labels, counts).
- **Accent family:** `blue` = informational/links, `green` = success/online,
  `amber` = pending/warning, `red` = destructive/error, `purple` = brand/
  primary action and focus (`ring`).

## Typography

`Outfit` for UI text, `JetBrains Mono` for IDs and technical values (asset
IDs, method names). The type scale is intentionally small and entirely
even-pixel: `xs` 12 · `sm` 14 · `base` 16 · `lg` 18 · `xl` 20 · `2xl` 24.
`xs` (12px) is the floor — nothing should render smaller than that; several
components previously used an arbitrary `11px` (and one `10px`), which is
both off-scale and under most legibility guidance.

## Layout

Spacing intentionally has no dedicated token scale here: Tailwind's default
spacing scale is a 4px grid (`4px × n`), which is already even-number-safe
by construction, so there is no drift risk to correct. Use Tailwind's
standard spacing utilities (`gap-2`, `px-4`, `py-1.5`, etc.).

## Shapes

Six-step radius scale, also entirely even-pixel: `sm` 4 · `md` 6 · `lg` 8 ·
`xl` 12 · `2xl` 16 · `full` 9999 (pill/circle). These match Tailwind v4's
own default radius scale exactly — nothing was changed numerically, the
scale is simply now named and documented so "card radius" and "button
radius" are deliberate choices instead of one bespoke `--radius` value
copied by hand into multiple places. Cards use `xl` (12px); buttons, pills,
and badges use `md` or `lg`; avatars/dots/status indicators use `full`.

## Components

- **Card**: `card` background, `card-foreground` text, `xl` radius,
  `border-subtle` 1px border. No shadow — separation comes from the border.
- **Button (primary)**: `accent-blue` background, `accent-foreground` text,
  `lg` radius.
- **Button (icon-only)**: no visible background at rest, `muted-foreground`
  icon color, `md` radius on hover background. Icon-only buttons **must**
  carry an `aria-label` describing the action (e.g. "Log out", "Delete
  organization") since there is no visible text for assistive tech to read.
- **Badge/pill**: paired `{color}-glow` background with solid `{color}`
  text (e.g. `accent-green-glow` bg + `accent-green` text) and a matching
  `border-{color}` — never mix color families within one badge (a bug
  found during this audit: an amber badge was rendering with a purple
  border and an undefined text color).

## Do's and Don'ts

- **Do** reference tokens through `var(--token-name)` (or Tailwind v4's
  `bg-(--token-name)` arbitrary-property syntax) — never hardcode a hex
  value in a component or in `clips.js`.
- **Do** keep badge/pill color families matched (background glow, text,
  and border all from the same semantic color).
- **Don't** introduce a new "theme" CSS file. If a visual variant is
  genuinely needed later, it should override individual tokens in
  `tokens.css`, not duplicate the whole file.
- **Don't** use arbitrary bracket values (`text-[11px]`, `rounded-[10px]`)
  for values that already have a scale step — use the named step instead.
- **Don't** write a bare `text-(--text-xs)` (or any `--text-*` scale
  token) on its own — Tailwind v4 treats unhinted `text-(--var)` as a
  **color** utility, not font-size, so it silently compiles to an invalid
  `color: var(--text-xs)` declaration that does nothing for size and can
  clobber a real text color elsewhere on the same element (this exact bug
  shipped once — a badge rendered with invisible/black text because of
  it). Always use the explicit type hint: `text-(length:--text-xs)`.
  Color tokens (`text-(--secondary)`, `text-(--accent-red)`, etc.) don't
  need a hint — bare `text-(--var)` is already correct for color.
