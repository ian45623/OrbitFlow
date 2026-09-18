# Design system: Foundation 1.0

The app's design system moves to the "quiet instrument with a legible pulse" direction
designed in Claude Design (`Orbit Flow.dc.html`, option 1a). This is the first of five
sub-projects from that file; onboarding, Settings, History and Dictionary all build on it.

Source: Claude Design project `9a584a41-ebbb-4ff3-bc34-a35043929068`, option 1a.

## What changes and what doesn't

1a is a refinement of the current system, not a replacement. The token names, the
one-accent rule, one step of depth, and no gradients all survive. What changes:

- **Three bundled typefaces** replace the system faces.
- **A warmer, flatter paper palette**, and a dark face derived to match it.
- **Metadata becomes instrumentation**: monospace, 10–11pt, uppercase, in a fixed slot.
- **New radius and spacing scales.**
- **Two new component roles**: the primary (filled) button and the step/status row.

## Typography

Three variable fonts ship inside the bundle under the SIL Open Font License:

| Role | Face | Used for |
|---|---|---|
| UI | Instrument Sans | Every interface label, button, heading, body line |
| Prose | Newsreader | Transcribed text, display headings ("Talk instead of type.") |
| Meta | JetBrains Mono | Timings, counts, statuses, shortcut keys, step counters |

Registration: the `.ttf` files live in `Resources/Fonts/`, the `app` target copies them to
`Contents/Resources/Fonts/`, and `Info.plist` carries `ATSApplicationFontsPath = Fonts`, so
AppKit registers them at launch with no code. `DS.Font` falls back to the current system
faces if a family is missing, so a bundle built without the fonts still renders.

`DS.Font` gains `meta` (10pt) and `metaEmphasis` (11pt, medium) for the mono slot, and
`display` moves to Newsreader at 28pt for onboarding's headline. `prose` stays at 14pt with
its 4pt extra leading and 620pt measure — rule 02 caps prose at 66 characters, which 620pt
at 14pt already approximates.

## Colour

Light values come from 1a. Dark values are derived here: the current graphite face, shifted
off blue to match the paper face's warmth, keeping every contrast ratio at or above today's.

| Token | Light | Dark | Role |
|---|---|---|---|
| canvas | FAFAF8 | 121211 | The window ground |
| surface | FFFFFF | 1A1A19 | Cards, rows, header |
| surfaceHover | F4F4F0 | 222220 | Pointer or selection |
| field | F1F1EC | 0D0D0C | Inset fields |
| line | E2E2DC | 2A2A27 | The one drawn line |
| ink | 141414 | EDEDE7 | Primary text |
| inkMuted | 57574F | A3A399 | Supporting text |
| inkFaint | 6F6F67 | 7A7A72 | Timestamps, placeholders |
| signal | C9342B | E04338 | Recording. Nothing else. |
| positive | 2F8259 | 4FA87A | A permission granted, a model ready |
| caution | A87A1E | D9A441 | Needs you before it works |
| focusRing | B4B8BE | 5B5B54 | Keyboard focus. Neutral by design. |

The HUD keeps its fixed dark palette: it sits over other apps and must not follow the
system appearance.

## Radius and spacing

Radius takes 1a's four steps: `chip` 6, `control` 8, `card` 12, `hud` 20. `window` is
retired — nothing used it but the HUD.

Spacing takes 1a's scale: 4, 8, 12, 16, 24, 36. The existing names survive except `panel`,
which moves from 32 to 36. `hair` (2) stays for the one place a 4pt grid can't express: the
gap inside a status dot.

## Components

`Components.swift` gains two roles and adjusts one:

- **`ActionButton` already has the three kinds 1a shows** — filled `primary`, outlined
  `secondary`, text-only `quiet` — and needs only the new radius and type. No new kind.
- **`StepRow`** — a collapsed row with a leading state disc (unfilled, `positive` tick, or
  `caution` ring), a title, a one-line description, and a meta slot on the right. Expanding
  reveals arbitrary content below the description. Onboarding is its first user; Settings
  reuses it for one-line setting rows.
- **`MetaLabel`** — mono, uppercase, `inkFaint`, fixed height, so a row's right-hand slot
  doesn't shift as its value changes.

## The five rules

`AGENTS.md`'s design-system section is rewritten to 1a's five rules, which subsume the
current four:

1. Hue never carries state. Surface and weight do. `signal` red means recording and
   nothing else; `positive` and `caution` appear only on status indicators, never as chrome.
2. Prose is serif and capped at 66 characters.
3. All metadata is mono, 10–11pt, uppercase, in a fixed slot.
4. One helper line per setting. Anything longer goes behind a "?".
5. Only the waveform moves on its own.

Rule 3 replaces the current "sentence case everywhere" rule, which is narrowed: sentence
case still governs headings, buttons, body text and settings labels. Uppercase is confined
to the mono metadata slot.

## Migration

Every existing view already reads tokens rather than literals, so the palette, radius and
spacing changes apply without touching view code. Three changes do reach views:

- `DS.Space.panel` 32 → 36 shifts padding in `MainWindow`, `SettingsWindow` and
  `ComparisonWindow`.
- `DS.Radius.window` is removed. No view references it.
- Metadata moves from `DS.Font.caption` to the new mono `DS.Font.meta`, uppercased. There
  are 29 `Font.caption` uses across the UI; each one is judged individually, because the
  token also carries help notes and sentences, which stay sans and sentence case.

Settings, History and Dictionary keep their current layouts in this sub-project. Their
redesigns (1d, 2a, 2c) follow as separate specs.

## Testing

The design system is presentation, and the app target can't be imported by a test target,
so verification is a build plus a look:

1. `make test` — the dictionary, rewrite and hotkey contract tests must still pass.
2. `make install` and open every surface: main window in both appearances, Settings,
   comparison window, the HUD while recording, the dictionary panel.
3. Confirm the three bundled families are registered:
   `/usr/bin/log show --last 2m --predicate 'subsystem == "ai.pivotstudio.orbitflow"'`
   plus a visual check that headings are Newsreader, not New York.
4. Check contrast for `inkFaint` on `canvas` in both faces — the value that carries the
   least contrast in the system — against WCAG AA for small text.

## Out of scope

- The dark face is derived here, not designed. If a dark design arrives from Claude Design
  later, it replaces these values; nothing else in this spec changes.
- Onboarding, Settings, History and Dictionary layouts.
