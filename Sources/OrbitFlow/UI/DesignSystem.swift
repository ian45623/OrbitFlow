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
/// The rules that keep this from drifting:
/// - **One accent.** `signal` is red, it means recording, and nothing else in the app
///   is ever red. Selection and focus are carried by surface and weight, not by hue.
/// - **Transcribed text is prose.** It gets the serif, generous leading and a capped
///   measure, because it is writing and not log output.
/// - **Depth is one step.** A surface lifts off the canvas by a hairline and a shade.
///   No bevels, no inner glow, no gradients anywhere.
/// - **Sentence case.** No tracked-out uppercase labels.
///
/// Views must not contain literal values. If a component needs a number that isn't a
/// token, add the token rather than inlining it.
enum DS {

    // MARK: - Color

    enum Color {
        /// The window ground. Everything sits on this.
        static let canvas = face(light: 0xF6F6F4, dark: 0x101216)

        /// A raised surface — cards, sheets, the header bar.
        static let surface = face(light: 0xFFFFFF, dark: 0x171A20)

        /// A surface under the pointer, or a selected segment.
        static let surfaceHover = face(light: 0xF0F0ED, dark: 0x1D2128)

        /// An inset field: search, text entry. Reads as cut into the surface.
        static let field = face(light: 0xF1F1EE, dark: 0x0B0D10)

        /// The one drawn line in the system. Separates rows, edges surfaces.
        static let line = face(light: 0xE3E3DF, dark: 0x262B33)

        // Text
        /// Primary text and headings.
        static let ink = face(light: 0x15171B, dark: 0xE9EBEF)
        /// Supporting text — engine names, counts, help notes.
        static let inkMuted = face(light: 0x5F646C, dark: 0x98A0AC)
        /// Timestamps, placeholders, anything you read only if you look for it.
        static let inkFaint = face(light: 0x92979F, dark: 0x636B77)

        // Accent — the only red in the app, and it only ever means "recording".
        static let signal = face(light: 0xC9342B, dark: 0xE04338)
        /// The record indicator at rest. A dark lens, not an absence.
        static let signalIdle = face(light: 0xDDD3D1, dark: 0x3A2A28)

        // The floating pill. Always dark, in both appearances — it sits over other
        // people's windows, and a HUD that follows the system theme reads as part of
        // whatever is behind it rather than as Orbit Flow.
        /// The pill's body. Dark and slightly translucent, over a blur.
        static let hudSurface = swatch(0x14161A, opacity: 0.88)
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
        static let focusRing = face(light: 0xB4B8BE, dark: 0x5B6472)

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

    /// Two roles, both from system faces so nothing ships with the app.
    ///
    /// **New York** (`.serif`) carries what the app produces: transcribed prose and the
    /// numbers you read while recording. **SF Pro** carries the interface around it.
    /// The split is the point — content reads as a document, chrome stays quiet.
    enum Font {
        // Interface
        /// Section headings and the window's few titles.
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// Buttons, tabs, field labels.
        static let label = SwiftUI.Font.system(size: 12, weight: .medium)
        /// Row metadata, help notes, counts.
        static let caption = SwiftUI.Font.system(size: 11)
        /// Interface body text — settings notes, dictionary terms.
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyEmphasis = SwiftUI.Font.system(size: 13, weight: .medium)

        // Content
        /// Transcribed text. Set like writing, because it is.
        static let prose = SwiftUI.Font.system(size: 14, design: .serif)
        /// A short serif line for empty states and sheet titles.
        static let display = SwiftUI.Font.system(size: 17, design: .serif)

        // Numerals
        /// Durations and timings inline in a row.
        static let numeral = SwiftUI.Font.system(size: 11, design: .serif).monospacedDigit()
        /// The elapsed counter while recording.
        static let counter = SwiftUI.Font.system(size: 15, design: .serif).monospacedDigit()

        /// Leading added to prose. Serif body wants more air than the sans.
        static let proseLeading: CGFloat = 4
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
        static let panel: CGFloat = 32
    }

    // MARK: - Radius

    /// Radius encodes role, so it varies rather than being one value on everything.
    /// The further an element floats from the window, the softer its corner.
    enum Radius {
        /// Inline tags and badges.
        static let chip: CGFloat = 5
        /// Buttons, fields, segments.
        static let control: CGFloat = 7
        /// A surface sitting on the canvas.
        static let card: CGFloat = 10
        /// A sheet or the window itself.
        static let window: CGFloat = 14
        /// The floating HUD. The softest thing in the app — it's an overlay, not a panel.
        static let hud: CGFloat = 18
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
        /// The HUD above someone else's app.
        static let hud = Spec(color: .black.opacity(0.30), radius: 24, y: 10)

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

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
