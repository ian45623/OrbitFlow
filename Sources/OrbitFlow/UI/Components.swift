import AppKit
import SwiftUI

// The visual vocabulary of the app: surfaces, labels, controls, and the one live element.
// Every value here comes from `DS`. If a component needs a number that isn't a token, the
// token is missing — add it there rather than inlining it.

// MARK: - Surfaces

/// A surface lifted off the canvas by a hairline and a shade. The only container in the
/// app: there is no second, heavier panel type, because one step of depth is the whole
/// elevation system.
struct Surface<Content: View>: View {
    var radius: CGFloat = DS.Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(DS.Color.surface, in: .rect(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(DS.Color.line, lineWidth: DS.Border.hairline)
            )
    }
}

/// The horizontal hairline that separates rows and sections. Rows are separated rather
/// than boxed — a list of transcripts is one document, not a stack of cards.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(DS.Color.line)
            .frame(height: DS.Border.hairline)
    }
}

// MARK: - Labels

/// A quiet interface label — section headings, field names, row metadata.
///
/// Sentence case, deliberately. Tracked-out uppercase reads as a machine talking; this
/// app is meant to sit under someone's attention, not shout for it.
struct FieldLabel: View {
    let text: String
    var color: Color = DS.Color.inkMuted
    var emphasis = false

    var body: some View {
        Text(text)
            .font(emphasis ? DS.Font.title : DS.Font.label)
            .foregroundStyle(color)
    }
}

/// A small bordered tag carrying one fact: which engine ran, which kind of rule this is.
struct Tag: View {
    let text: String
    var color: Color = DS.Color.inkMuted

    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(color)
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.hair)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(color.opacity(0.3), lineWidth: DS.Border.hairline)
            )
    }
}

/// Monospaced-digit numerals — durations, timings, the elapsed counter. Serif, so the
/// figures sit with the transcript rather than looking bolted on from a terminal.
struct Numeral: View {
    let text: String
    var large = false
    var color: Color = DS.Color.inkMuted

    var body: some View {
        Text(text)
            .font(large ? DS.Font.counter : DS.Font.numeral)
            .foregroundStyle(color)
    }
}

/// A small filled circle reporting a binary state — a rule that's on, an engine that ran.
/// Not used for recording; that has its own control.
struct StatusDot: View {
    var color: Color = DS.Color.positive
    var isOn: Bool
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(isOn ? color : DS.Color.inkFaint.opacity(0.35))
            .frame(width: size, height: size)
            .animation(DS.Motion.signal, value: isOn)
    }
}

// MARK: - Controls

/// The app's button.
///
/// Three weights, and the choice is about consequence rather than decoration: `primary`
/// for the one action a view exists to perform, `secondary` for everything alongside it,
/// `quiet` for actions that should be findable but never draw the eye.
struct ActionButton: View {
    enum Kind { case primary, secondary, quiet }

    let title: String
    var systemImage: String?
    var kind: Kind = .secondary
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.tight) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(DS.Font.label)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? DS.Space.snug : DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .background(background)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 && isEnabled }
        .animation(DS.Motion.press, value: isHovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary: DS.Color.surface
        case .secondary: DS.Color.ink
        case .quiet: isHovering ? DS.Color.ink : DS.Color.inkMuted
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary:
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Color.ink.opacity(isHovering ? 0.85 : 1))
        case .secondary:
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(isHovering ? DS.Color.surfaceHover : DS.Color.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .strokeBorder(DS.Color.line, lineWidth: DS.Border.hairline)
                )
        case .quiet:
            Color.clear
        }
    }
}

/// Pick one of a few. A row of plain words in a recessed track — the selected one lifts
/// onto a surface. No hue involved, so it stays legible with the accent spoken for.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: DS.Space.hair) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection == option.value
                Button {
                    withAnimation(DS.Motion.panel) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(DS.Font.label)
                        .foregroundStyle(isSelected ? DS.Color.ink : DS.Color.inkMuted)
                        .padding(.horizontal, DS.Space.base)
                        .padding(.vertical, DS.Space.snug)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: DS.Radius.control - DS.Space.hair)
                                    .fill(DS.Color.surface)
                            }
                        }
                        // Without this the segment is only clickable on the letterforms.
                        // A `.plain` button hit-tests what its label actually draws, and an
                        // *unselected* segment draws nothing but the word — the padding and
                        // the `maxWidth: .infinity` that make it look like a wide target are
                        // empty space. The selected one works, which is what makes the bug
                        // read as "sometimes it ignores me" rather than as a dead zone.
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.hair)
        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
    }
}

/// Search. An inset field with the glass at the head of it and nothing else — no border,
/// no button, and the clear control only exists once there's something to clear.
struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DS.Color.inkFaint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Color.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
    }
}

/// A labelled text field in a sheet.
struct EntryField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            FieldLabel(text: label)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .padding(.horizontal, DS.Space.base)
                .padding(.vertical, DS.Space.snug)
                .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .strokeBorder(DS.Color.line, lineWidth: DS.Border.hairline)
                )
        }
    }
}

/// The record control. The one place the accent appears: a red disc while live, a hollow
/// ring at rest. It becomes a square when recording, so the state reads without color for
/// anyone who can't distinguish it.
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    private let diameter: CGFloat = 28

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isRecording ? DS.Color.signal : DS.Color.inkFaint,
                        lineWidth: DS.Border.emphasis
                    )
                RoundedRectangle(cornerRadius: isRecording ? DS.Space.hair : diameter)
                    .fill(isRecording ? DS.Color.signal : DS.Color.signalIdle)
                    .frame(
                        width: isRecording ? diameter * 0.36 : diameter * 0.5,
                        height: isRecording ? diameter * 0.36 : diameter * 0.5
                    )
            }
            .frame(width: diameter, height: diameter)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.signal, value: isRecording)
        .help(isRecording ? "Stop recording" : "Start recording")
    }
}

// MARK: - The live element

/// A scrolling waveform of what the microphone is hearing.
///
/// Newest sample on the right, older ones drifting left, mirrored around the centre —
/// the shape of a recording rather than a row of pumping bars. It is the only thing in
/// the app that moves on its own, which is why everything around it stays still.
struct Waveform: View {
    /// Current input level, 0...1.
    let level: Float
    var isActive: Bool
    var color: Color = DS.Color.ink

    /// The trace lives in a plain reference type, deliberately *not* in `@State`. It has
    /// to advance once per drawn frame, and SwiftUI state mutated inside a `Canvas` draw
    /// closure is a mutation during view update — which SwiftUI logs as undefined
    /// behaviour and which, at 120fps, floods the process. A reference the view merely
    /// holds is invisible to the state graph, so stepping it is safe.
    @State private var trace = Trace()

    private final class Trace {
        var samples: [Double] = []
        var smoothed: Double = 0
        var lastSample: Date = .distantPast
    }

    private static let pitch = DS.Wave.barWidth + DS.Wave.barGap

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / DS.Motion.traceHz, paused: !isActive)) { timeline in
            Canvas { context, size in
                let capacity = Int(size.width / Self.pitch)
                advance(to: timeline.date, capacity: max(capacity, 1))
                draw(in: &context, size: size, capacity: max(capacity, 1))
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    /// Appends at a fixed rate rather than once per frame, so the trace scrolls at the
    /// same speed on a 60Hz panel as on a 120Hz one.
    private func advance(to date: Date, capacity: Int) {
        let interval = 1 / DS.Motion.traceHz
        guard date.timeIntervalSince(trace.lastSample) >= interval else { return }
        trace.lastSample = date

        // The level arrives already mapped from −50…0 dBFS, which puts ordinary speech
        // around a third of full scale. Drawn straight, that's a few points of movement in
        // a pill this small — technically correct and visually dead. The exponent expands
        // the quiet end, where speech actually lives, without clipping the loud end.
        let raw = isActive ? Double(min(max(level, 0), 1)) : 0
        let target = pow(raw, DS.Wave.gain)
        let carry = DS.Motion.traceSmoothing
        trace.smoothed = trace.smoothed * carry + target * (1 - carry)

        trace.samples.append(trace.smoothed)
        if trace.samples.count > capacity {
            trace.samples.removeFirst(trace.samples.count - capacity)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, capacity: Int) {
        let midY = size.height / 2

        for (index, sample) in trace.samples.enumerated() {
            // Right-align: a partially-filled buffer grows in from the right edge.
            let slot = capacity - trace.samples.count + index
            let x = CGFloat(slot) * Self.pitch
            let height = max(DS.Wave.restHeight, CGFloat(sample) * size.height)
            let bar = CGRect(x: x, y: midY - height / 2, width: DS.Wave.barWidth, height: height)
            context.fill(
                Path(roundedRect: bar, cornerRadius: DS.Wave.barWidth / 2),
                // Older samples fade, so the eye lands on what's being said now.
                with: .color(color.opacity(
                    DS.Wave.tailOpacity
                        + (1 - DS.Wave.tailOpacity) * Double(index) / Double(max(capacity - 1, 1))
                ))
            )
        }
    }
}

/// A circular control on the dictation pill.
///
/// Confirm is the bright one and discard is grey, because finishing is what you do every
/// time and throwing the utterance away is the rare escape hatch. Both are the same size:
/// the difference in weight is carried by fill, not by making one harder to hit.
struct HUDButton: View {
    enum Kind { case discard, confirm }

    let kind: Kind
    let size: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(kind == .confirm ? DS.Color.hudConfirm : DS.Color.hudControl)
                .overlay {
                    Image(systemName: kind == .confirm ? "checkmark" : "xmark")
                        .font(.system(size: size * 0.44, weight: .bold))
                        .foregroundStyle(
                            kind == .confirm ? DS.Color.hudGlyphOnConfirm : DS.Color.inkOnHUD
                        )
                }
                .frame(width: size, height: size)
                .brightness(isHovering ? 0.08 : 0)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(DS.Motion.press, value: isHovering)
        .help(kind == .confirm ? "Stop and paste" : "Discard this recording")
    }
}

// MARK: - Empty states

/// An empty screen is an invitation to act, so the headline is the invitation and the
/// detail says what will happen.
struct EmptyPanel: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(spacing: DS.Space.snug) {
            Text(label)
                .font(DS.Font.display)
                .foregroundStyle(DS.Color.ink)
            Text(detail)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.panel)
    }
}

/// Copy-to-clipboard with the acknowledgement built in. Every place that offers a copy
/// wants the same brief "Copied" flip, so the flip lives here rather than in each caller.
struct CopyButton: View {
    let text: String
    var title = "Copy"
    var kind: ActionButton.Kind = .quiet

    @State private var didCopy = false

    var body: some View {
        ActionButton(title: didCopy ? "Copied" : title, kind: kind) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                didCopy = false
            }
        }
    }
}

/// A multi-line box for transcript-sized text: same inset field as `EntryField`, but set
/// in prose, because what gets typed into it is prose rather than a setting.
struct ProseEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 96

    var body: some View {
        TextEditor(text: $text)
            .font(DS.Font.prose)
            .lineSpacing(DS.Font.proseLeading)
            .foregroundStyle(DS.Color.ink)
            .scrollContentBackground(.hidden)
            .padding(DS.Space.snug)
            .frame(minHeight: minHeight)
            .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.line, lineWidth: DS.Border.hairline)
            )
    }
}

/// Lays children out in a row and wraps to the next line when they don't fit.
///
/// SwiftUI has no wrapping stack. A horizontal `ScrollView` is the usual substitute, but
/// it hides items off the edge — which is the wrong trade for a set of choices the user
/// is supposed to be comparing at a glance.
struct Flow: Layout {
    var spacing: CGFloat = DS.Space.snug
    var lineSpacing: CGFloat = DS.Space.snug

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = lay(subviews, in: width)
        let height = rows.map(\.height).reduce(0, +)
            + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lay(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func lay(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows = [Row()]
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(Row())
                x = 0
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }
}
