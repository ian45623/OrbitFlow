import AppKit
import SwiftUI

/// The design system for Orbit Flow.
///
/// Direction: **quiet instrument**. This app's job is to disappear — you hold a key,
/// speak, and text lands in someone else's window. The interface is mostly negative
/// space with one live element in it, and it sits on top of the work rather than
/// competing with it.
///
/// Two faces: cool graphite in dark appearance, warm-neutral paper in light. Same token
/// names, so a view is written once and both faces work.
///
/// The five rules that keep this from drifting:
/// 1. **Hue never carries state.** Surface and weight do. `signal` is red, it means
///    recording, and nothing else in the app is ever red. `positive` and `caution` appear
///    on status indicators only, never as chrome.
/// 2. **Prose is serif**, capped at 66 characters, because it is writing and not log output.
/// 3. **All metadata is mono**, 10–11pt, uppercase, in a fixed slot — timings, counts,
///    statuses. Everything else is sentence case.
/// 4. **One helper line per setting.** Anything longer goes behind a "?".
/// 5. **Only the waveform moves on its own.**
///
/// Depth is one step: a hairline and a shade. No bevels, no inner glow, no gradients.
///
/// Views must not contain literal values. If a component needs a number that isn't a
/// token, add the token rather than inlining it.
enum DS {

    // MARK: - Color

    enum Color {
        // Paper in light, graphite in dark. The light values are Foundation 1.0's; the
        // dark ones are the same hues carried across, off blue so both faces read warm.
        /// The window ground. Everything sits on this.
        static let canvas = face(light: 0xFAFAF8, dark: 0x121211)

        /// A raised surface — cards, sheets, the header bar.
        static let surface = face(light: 0xFFFFFF, dark: 0x1A1A19)

        /// A surface under the pointer, or a selected segment.
        static let surfaceHover = face(light: 0xF4F4F0, dark: 0x222220)

        /// An inset field: search, text entry. Reads as cut into the surface.
        static let field = face(light: 0xF1F1EC, dark: 0x0D0D0C)

        /// The one drawn line in the system. Separates rows, edges surfaces.
        static let line = face(light: 0xE2E2DC, dark: 0x2A2A27)

        // Text
        /// Primary text and headings.
        static let ink = face(light: 0x141414, dark: 0xEDEDE7)
        /// Supporting text — engine names, counts, help notes.
        static let inkMuted = face(light: 0x57574F, dark: 0xA3A399)
        /// Timestamps, placeholders, anything you read only if you look for it.
        static let inkFaint = face(light: 0x6F6F67, dark: 0x7A7A72)

        // Accent — the only red in the app, and it only ever means "recording".
        static let signal = face(light: 0xC9342B, dark: 0xE04338)
        /// The record indicator at rest. A dark lens, not an absence.
        static let signalIdle = face(light: 0xDDD3D1, dark: 0x3A2A28)

        // The floating pill. Always dark, in both appearances — it sits over other
        // people's windows, and a HUD that follows the system theme reads as part of
        // whatever is behind it rather than as Orbit Flow.
        /// The pill's body. Near-solid dark — no material behind it, because a blur
        /// picks up the wallpaper and haloes the capsule's edge.
        static let hudSurface = swatch(0x14161A, opacity: 0.96)
        /// A light hairline, so a dark pill still has an edge on a dark background.
        static let hudEdge = SwiftUI.Color.white.opacity(0.16)
        /// Text on the pill.
        static let inkOnHUD = swatch(0xF0F2F5)
        /// Secondary text on the pill.
        static let inkOnHUDMuted = swatch(0x99A1AD)
        /// The discard control: a grey disc, subordinate to the confirm button next to it.
        static let hudControl = swatch(0x4A4E55)
        /// The confirm control: the one bright thing on the pill, because finishing is the
        /// action you take every time and discarding is the one you rarely take.
        static let hudConfirm = swatch(0xF5F6F8)
        /// Glyph on the confirm disc.
        static let hudGlyphOnConfirm = swatch(0x16181C)

        /// Keyboard focus. Neutral on purpose — red is spoken for.
        static let focusRing = face(light: 0xB4B8BE, dark: 0x5B5B54)

        // Status. Used on indicators and verdicts, never as UI chrome.
        /// A rule that's on, an engine that agreed.
        static let positive = face(light: 0x2F8259, dark: 0x4FA87A)
        /// A warning worth reading before saving.
        static let caution = face(light: 0xA87A1E, dark: 0xD9A441)

        // MARK: Face resolution

        /// A fixed colour, the same in both appearances.
        private static func swatch(_ hex: UInt32, opacity: Double = 1) -> SwiftUI.Color {
            SwiftUI.Color(
                .sRGB,
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                opacity: opacity
            )
        }

        /// Resolves to the paper or graphite value for the current appearance.
        private static func face(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
        }
    }

    // MARK: - Type

    /// Three roles, three faces, all bundled in `Contents/Resources/Fonts` and registered
    /// by `ATSApplicationFontsPath` in Info.plist.
    ///
    /// **Source Serif 4** carries what the app produces: transcribed prose and the
    /// display lines. **Instrument Sans** carries the interface around it. **JetBrains
    /// Mono** carries instrumentation — timings, counts, statuses — which is why those
    /// read as measurements rather than as more interface.
    ///
    /// The serif is Source Serif rather than a finer text face because transcripts are
    /// read in three-line previews at 15pt, where stroke contrast turns into mush. Its
    /// x-height is ~11% taller than Newsreader's at the same size, so the same point
    /// value reads noticeably larger.
    ///
    /// All three are variable fonts. macOS resolves the optical-size axis against the
    /// point size on its own, so `face` sets no variation — asking for 15pt already
    /// gets the 15pt drawing.
    ///
    /// Every role falls back to the system face it replaced, so a bundle built without the
    /// font files still renders: `custom(_:size:)` resolves to the system font when the
    /// family is missing, and `fallback` keeps the serif and mono intent in that case.
    enum Font {
        /// Family names as CoreText reports them.
        private static let ui = "Instrument Sans"
        private static let serif = "Source Serif 4"
        private static let mono = "JetBrains Mono"

        /// `Font.custom` silently falls back to the system face, but loses `design`, so the
        /// serif and mono intents are restated here for the no-font-files case.
        private static func face(
            _ family: String,
            _ size: CGFloat,
            weight: SwiftUI.Font.Weight = .regular,
            fallback: SwiftUI.Font.Design = .default
        ) -> SwiftUI.Font {
            guard NSFont(name: family, size: size) != nil else {
                return .system(size: size, weight: weight, design: fallback)
            }
            return .custom(family, fixedSize: size).weight(weight)
        }

        // Interface
        /// Section headings and the window's few titles.
        static let title = face(ui, 15, weight: .semibold)
        /// Buttons, tabs, field labels.
        static let label = face(ui, 12, weight: .medium)
        /// Help notes and sentences that sit under a control. Sans, sentence case —
        /// metadata belongs in `meta`, not here.
        static let caption = face(ui, 11)
        /// Interface body text — settings notes, dictionary terms.
        static let body = face(ui, 13)
        static let bodyEmphasis = face(ui, 13, weight: .medium)

        // Instrumentation. Rule 3: mono, 10–11pt, uppercase, in a fixed slot.
        /// Row metadata, statuses, counts. Uppercase at the call site via `MetaLabel`.
        static let meta = face(mono, 10, fallback: .monospaced)
        /// The same slot when it carries the row's primary fact — a captured key, a step
        /// counter — and needs to hold its own against the title next to it.
        static let metaEmphasis = face(mono, 11, weight: .medium, fallback: .monospaced)

        // Content
        /// Transcribed text. Set like writing, because it is.
        static let prose = face(serif, 15, fallback: .serif)
        /// A short serif line for empty states and sheet titles.
        static let display = face(serif, 17, fallback: .serif)
        /// The one headline size in the app — onboarding's "Talk instead of type."
        static let headline = face(serif, 28, fallback: .serif)

        // Numerals
        /// Durations and timings inline in a row.
        static let numeral = face(mono, 11, fallback: .monospaced).monospacedDigit()
        /// The elapsed counter while recording.
        static let counter = face(mono, 15, fallback: .monospaced).monospacedDigit()

        /// Leading added to prose. Serif body wants more air than the sans, and a
        /// three-line preview wants it most — without this the lines knit together and
        /// the row reads as a block rather than as sentences.
        static let proseLeading: CGFloat = 6
        /// Longest comfortable transcript line before it should wrap.
        static let proseMeasure: CGFloat = 620
    }

    // MARK: - Spacing

    /// A 4pt grid. Nothing sits between steps.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let wide: CGFloat = 24
        static let panel: CGFloat = 36
    }

    // MARK: - Layout

    /// Pane geometry for the Recent tab's three columns.
    ///
    /// The list's width is a *fraction* of the space the list and detail share, not a
    /// point value. One number then answers three questions that used to disagree:
    /// dragging the divider sets it, collapsing the rail widens the space it divides, and
    /// resizing the window does the same. A stored point width answers only the first,
    /// which is why the panes used to sit still while everything around them moved.
    enum Layout {
        /// The filter rail, labels showing.
        static let railOpen: CGFloat = 200
        /// The filter rail as a strip of icons. Still clickable, which is the point.
        static let railClosed: CGFloat = 52

        /// Narrowest useful list: below this the time, the latency and the status badge
        /// stop fitting on one line and the row header wraps.
        static let listMin: CGFloat = 320
        /// Widest useful list. A three-line preview past this is a paragraph, and the
        /// list's job is to be scanned, not read.
        static let listMax: CGFloat = 560
        /// The list's share of the list+detail pair before anyone drags it.
        static let listFraction: Double = 0.36

        /// The detail keeps this much even when the list is dragged wide.
        static let detailMin: CGFloat = 360
        /// Longest line of transcript in the detail. Rule 2's measure, in points.
        static let detailMeasure: CGFloat = 680

        /// The divider's grab area. The line itself is one point; one point is not a
        /// target, so the gesture gets this much to either side.
        static let dividerGrab: CGFloat = 8

        /// The list's width for a stored fraction and the space the two panes share.
        ///
        /// Clamped twice over: once to the list's own readable range, and once to
        /// whatever is left after the detail takes its minimum — so dragging the divider
        /// to the far right stops at a usable detail rather than crushing it.
        static func listWidth(fraction: Double, available: CGFloat) -> CGFloat {
            let ceiling = max(listMin, min(listMax, available - detailMin))
            return min(max(fraction * available, listMin), ceiling)
        }

        /// The fraction that puts the list at `width`, for writing a drag back to storage.
        static func listFraction(forWidth width: CGFloat, available: CGFloat) -> Double {
            guard available > 0 else { return listFraction }
            return Double(listWidth(fraction: width / available, available: available) / available)
        }
    }

    // MARK: - Radius

    /// Radius encodes role, so it varies rather than being one value on everything.
    /// The further an element floats from the window, the softer its corner.
    enum Radius {
        /// Inline tags and badges.
        static let chip: CGFloat = 6
        /// Buttons, fields, segments.
        static let control: CGFloat = 8
        /// A surface sitting on the canvas.
        static let card: CGFloat = 12
        /// The floating HUD. The softest thing in the app — it's an overlay, not a panel.
        static let hud: CGFloat = 20
    }

    // MARK: - Border

    enum Border {
        /// The one line weight. Not scaled — 1pt reads as a drawn edge at any density.
        static let hairline: CGFloat = 1
        /// The active tab's underline, and the record ring.
        static let emphasis: CGFloat = 2
    }

    // MARK: - Elevation

    /// One step of depth, applied sparingly. Anything on the canvas is flat; only things
    /// that genuinely float get a shadow.
    enum Shadow {
        /// A sheet above the window.
        static let sheet = Spec(color: .black.opacity(0.22), radius: 28, y: 10)
        /// The HUD above someone else's app. Deliberately tight: a wide soft shadow
        /// around a 26pt pill reads as a glow, not as depth.
        static let hud = Spec(color: .black.opacity(0.28), radius: 6, y: 2)

        struct Spec {
            let color: SwiftUI.Color
            let radius: CGFloat
            var x: CGFloat = 0
            let y: CGFloat
        }
    }

    // MARK: - Motion

    /// Motion answers an action. The only thing that moves on its own is the waveform,
    /// because it is showing live input.
    enum Motion {
        /// A control acknowledging a press.
        static let press = Animation.easeOut(duration: 0.10)
        /// A panel, tab or sheet changing.
        static let panel = Animation.easeInOut(duration: 0.20)
        /// The record indicator arming. Immediate — it's reporting state, not animating.
        static let signal = Animation.easeOut(duration: 0.09)

        /// Waveform sample rate. Also the scroll speed of the trace.
        static let traceHz: Double = 30
        /// How much of the previous sample carries into the next, 0...1. Enough to take
        /// the jitter off the trace, low enough that a syllable still reads as a spike.
        static let traceSmoothing: Double = 0.18
    }

    // MARK: - Waveform

    /// The scrolling level trace. Its own group because the numbers are a *response
    /// curve*, not styling — they decide whether talking normally visibly moves the meter.
    enum Wave {
        /// Bar geometry. Narrow and tightly spaced, so the trace reads as a waveform
        /// rather than as a row of blocks.
        static let barWidth: CGFloat = 2
        static let barGap: CGFloat = 1.5

        /// Exponent applied to the 0...1 level before drawing.
        ///
        /// `AudioCapture` already maps −50…0 dBFS onto 0…1, which puts ordinary speech
        /// near 0.35 — a third of the height, which in a pill a few points tall is barely
        /// a flicker. An exponent below 1 expands the quiet end where all the speech
        /// actually lives, without clipping the loud end.
        static let gain: Double = 0.55

        /// Height of a bar at rest. Two points reads as a row of dots, which is what an
        /// idle trace should look like — silence is a fact, not an empty box.
        static let restHeight: CGFloat = 2

        /// How faint the oldest bar in the trace is, so the eye lands on the newest.
        static let tailOpacity: Double = 0.28
    }
}

// MARK: - Hex helpers

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
