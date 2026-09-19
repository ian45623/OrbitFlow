# AI Models: one page for the three models

Settings' second section is "Speech model", and it answers one question: what transcribes
your voice. Two other model choices live elsewhere and are not recognisable as the same
kind of decision — which model rewrites text (implicit, on Cleanup & AI) and which voice
reads it back (a segmented control on Read aloud).

This replaces that section with **AI Models**: one page where Speech to text, Rewrite and
Read aloud each choose between **Apple · Local · Cloud**, with downloads and state handled
in one place. Detailed configuration — API keys, model IDs, voices, speeds, reading modes —
stays where it is.

One model becomes newly downloadable: **Kokoro**, for Read aloud. Parakeet already is. The
recommended fully-local setup is therefore **Parakeet + Apple Intelligence + Kokoro**, all
three of which are reachable without adding a dependency — see "No third rewrite model" for
why Qwen 1.7B is not part of it.

## Layout

The window is 860×600 (`SettingsWindow`), so the content pane is ~610pt. No scrolling.

**Header.** Title in `DS.Font.display`, one subtitle line, and on the right a readout boxed
in `Surface` at ~210pt:

```
Quality  ▓▓▓▓▓▓░░░  Excellent
Speed    ▓▓▓▓▓▓▓░░  Fast
─────────────────────────────
Runs on          ● This Mac
```

Quality and Speed are bars because they are quantities. `Runs on` is a hairline below them
with no bar, because where the work happens is not one — a green dot and "This Mac", or a
`caution` dot and "Mac + cloud" the moment any job is set to Cloud. The dot never carries
the state alone (rule 01); the words always say it too.

**Body.** Three `Surface` panels, one per job, 11pt apart. Each holds:

- Job name in `DS.Font.display` (Source Serif 17) and its purpose in `caption`. The three
  jobs are what the page is for, so they outrank the model names inside them.
- A `Segmented` — **Apple · Local · Cloud** — at most 330pt. Three short parallel words.
- A hairline, then the state of whatever is selected: model name, one line, a status in
  `MetaLabel`, and an action on the right (Download / Remove / Configure).

The segmented control keeps the `field` tint because it is a control; the state below it
sits plain on `surface`. An earlier draft tinted both and read as two grey blocks at
different indents.

Three panels rather than one is a deliberate departure from `Hairline`'s note that "rows are
separated rather than boxed". Each job is a distinct object with its own state machine, not
a row in a list, and the user asked for the stronger separation. Depth stays at one step —
`Surface` is still the only container.

## The three jobs

| Job | Apple | Local | Cloud |
|---|---|---|---|
| Speech to text | `SpeechTranscriber`, streams while you speak | Parakeet, 470 MB | disabled — Orbit Flow has no cloud speech engine |
| Rewrite | Apple Intelligence (`OnDeviceRewriter`) | disabled — Apple Intelligence already is the local model | the five `AIProvider` cases |
| Read aloud | `AVSpeechSynthesizer` system voices | **Kokoro** | ElevenLabs |

**A segment with nothing behind it is disabled and says why on hover.** One rule, applied
twice:

- Speech to text ▸ Cloud — "Orbit Flow has no cloud speech engine. Audio never leaves this
  Mac."
- Rewrite ▸ Local — "Apple Intelligence is the local model. It already runs on this Mac."

Both rows keep three segments, so every control is the same width down the page and the
rows align. Neither message is a dead end: each says something true the user may not know.
Nothing on the page is selectable and inert.

## Grades

Quality and speed are **authored constants**, not measurements — nothing in the app
benchmarks anything. They live in one file, `ModelGrade.swift`, with the reasoning in
comments, so revising them is one diff rather than a hunt through views. Three grades each,
1–3: Good, Excellent, Exceptional.

| Job ▸ option | Quality | Speed |
|---|---|---|
| Speech ▸ Apple | Good | Instant |
| Speech ▸ Parakeet | Excellent | Fast |
| Rewrite ▸ Apple Intelligence | **Excellent** | Instant |
| Rewrite ▸ Cloud | Exceptional | Network |
| Read aloud ▸ Apple | **derived — see below** | Instant |
| Read aloud ▸ Kokoro | Excellent | Fast |
| Read aloud ▸ ElevenLabs | Exceptional | Network |

Apple Intelligence grades **Excellent**, not Good. It is a ~3B model Apple built for
summarization and refinement — the job Orbit Flow actually asks of it — and it is now the
recommended local rewrite. Grading it Good would push people toward Cloud for no reason
this app believes in.

**Read aloud ▸ Apple is the one grade that is computed**, because "Apple TTS" is not one
thing: a default system voice is mediocre and a Premium one is very good.
`AVSpeechSynthesisVoice.quality` already drives the picker labels in
`SettingsPanel.voiceLabel`, so the grade reads the selected voice: `.default` → Good,
`.enhanced` → Excellent, `.premium` → Exceptional. A user with a Premium voice installed
can therefore see Apple outrank Kokoro, which is true and worth telling them.

To keep the grade function pure and testable it takes a `VoiceGrade` enum, and the view maps
AVFoundation's type onto it — `OrbitFlowModels` does not import AVFoundation.

The header's two bars are the mean of the three selected jobs over 3.0; the word is the
rounded mean. Cloud's "Exceptional" is a claim about the tier, not the user's configured
model — a cheap model would light the same bar. Accepted knowingly: the alternative is a
model-ID-to-grade table that goes stale every time a provider ships.

**Download sizes are measured, not guessed.** Parakeet's 470 MB is confirmed in
`ParakeetModels`. Kokoro's figure is obtained by downloading it once during implementation
and reading the installed size, then written into `ModelGrade` with a comment naming the
model repo it was measured from. No size is asserted in this spec that has not been
measured.

## `ManagedModel`

`ParakeetDownload` is already the right shape — an `@Observable` with a four-case phase,
shared by Settings, the menu bar, and a dictation that triggers the download. Generalise it
so Kokoro is a sibling rather than a copy:

```swift
@MainActor protocol ManagedModel: AnyObject, Observable {
    var id: String { get }
    var displayName: String { get }
    var downloadSize: String { get }      // "470 MB", measured once and written in
    var phase: ModelPhase { get }         // missing / working(label, fraction) / ready / failed
    var installedSize: Int64? { get }
    func start()
    func removeFromDisk()
}
```

`ParakeetDownload` conforms with no behaviour change. `KokoroDownload` conforms alongside.
One SwiftUI view, `ModelStateCard`, renders any conformer. A future local model is then a
conformance and a `ModelGrade` row rather than a screen — which is the point of the protocol
even though only two models exist today.

`ModelPhase` is `ParakeetDownload.Phase` lifted out verbatim, including `.working(label:
fraction:)` — the named phases exist because the compile step after a download is slow and
silent, and a bar parked at 100% reads as a hang.

## Kokoro

FluidAudio 0.15.6 is already pinned and ships `KokoroAneManager`: a 7-stage CoreML chain on
the ANE. **No new dependency.** Two facts make it cheap:

- `synthesize(text:voice:speed:)` returns 24 kHz mono **WAV `Data`** — exactly what
  `Speaker.playRendered(_:)` already plays for ElevenLabs. No new audio path.
- `KokoroAneResourceDownloader.ensureModels(progressHandler:)` reports the same
  `DownloadProgress` that `ParakeetDownload.report(_:)` already consumes.

`VoiceEngine` gains `.kokoro`. `Speaker.speak(_:)` gains a third branch that sets
`isPreparing`, synthesises off the main actor, and hands the WAV to `playRendered`.
Synthesis is not instant, so it uses the same in-flight guard as ElevenLabs.

Models land in `~/.cache/fluidaudio/Models/<repo>` (`TtsCacheDirectory`), not the
Application Support path Parakeet uses. `KokoroDownload` reads that directory for
`isDownloaded`, size and removal — the three must agree on one definition, as
`ParakeetModels.directory` already does.

**OS guard.** FluidAudio warns that macOS 26.4–26.5 carry an Apple BNNS bug that
intermittently crashes Kokoro synthesis (FluidInference/FluidAudio#844); 26.6 fixes it. The
package targets macOS 26. On an affected build the Local segment for Read aloud is disabled
with a reason naming the OS version, rather than offering a download that can crash.

Voice choice stays on the Read aloud page: a picker of Kokoro voices when Kokoro is
selected, defaulting to `af_heart`, beside the existing system-voice picker.

## Settings

```swift
enum ModelSource: String, CaseIterable, Sendable { case apple, local, cloud }
```

`ModelSource` is what the three segmented controls bind to, but it is **stored only once**.
Two of the three jobs already have a property that expresses the same decision, and
`AIRewriteUse` states the principle this page must not break: *"Two properties expressing
one decision is how they drift."*

| Job | Stored | `ModelSource` is |
|---|---|---|
| Speech to text | `engine: SpeechEngineChoice` (`apple`, `parakeet`) | computed: `.parakeet` → `.local` |
| Read aloud | `readAloudEngine: VoiceEngine`, gaining `.kokoro` | computed: `.system` → `.apple`, `.kokoro` → `.local`, `.elevenLabs` → `.cloud` |
| Rewrite | **new** `rewriteSource: ModelSource` | itself |

So the page adds one stored property, not three, and `VoiceEngine` gaining a case is what
makes Read aloud's three-way choice expressible at all. Each control binds through a
computed `Binding` that writes the underlying enum; nothing can disagree because there is
nothing to disagree with. `readAloudLocalVoice` is added for the Kokoro voice name.

**Migration**, in `Settings.init`: only Rewrite needs one, since the other two rows read
properties that already exist. `rewriteSource` = `.cloud` if a key is stored **and**
`aiModel` is non-empty, else `.apple`.

That row is the one with teeth. Today there is **no** rewrite-engine setting:
`OnDemandRewrite.engine(use:hasKey:model:onDeviceAvailable:)` returns `.cloud` whenever a
key and model exist and `.onDevice` otherwise. Making the choice explicit means a user with
a key who wanted Apple Intelligence can finally say so — and means the migration must
reproduce the old implicit rule, or existing users silently change engines.

`OnDemandRewrite.engine` gains a `source: ModelSource` parameter. `.local` is unreachable
while that segment is disabled, and maps to `.onDevice` — for rewriting, Apple Intelligence
*is* the local model, so that is the honest mapping rather than a placeholder. It keeps its
fallbacks:
Cloud without a working key still falls back rather than failing, because that path is
reached from the Services menu where a silent no-op reads as a broken feature. It is pure,
lives in a testable target, and has tests — so it is written test-first.

## What moves, and what does not

AI Models becomes the only place an engine is **chosen**. No control appears twice.

- **Cleanup & AI** loses its Provider picker; keeps when-to-rewrite, mode, API key, model
  ID, Test. Its Cloud card's "Configure" button opens it.
- **Read aloud** loses the `System | ElevenLabs` segmented control; keeps the on/off toggle,
  reading modes, voice pickers, speed, preview, ElevenLabs key and voice.

## Removed: compare engines

`Settings.compareMode` and everything reached from it. The feature ran both engines and
opened a window instead of typing, which no longer has a place on a page about choosing one
model. Touches: `EngineComparison`, `ComparisonWindow`, `WisprTrigger`,
`DictationController` (`isComparing`, the compare branch), `OrbitFlowApp` (menu toggle,
window, `showComparisonWindow`), `DashboardHTML.emptyState`, `RunLog`, `Settings`.

`RunLog`'s stored `compareMode` field stays readable so existing history still decodes; it
is simply never written `true` again.

## Testing

Logic goes where it can be tested — the app target is an executable and cannot be imported
by a test target, which is why `OrbitFlowAIRewrite` and friends exist.

- `OnDemandRewrite.engine` with the new `source`: each source × key present/absent × model
  blank/set × on-device available/not. Written first; the existing suite pins today's
  behaviour and must keep passing under the migration rule.
- `ModelGrade` aggregation: the mean and its word for every combination of three sources,
  and that `Runs on` is "Mac + cloud" iff any source is `.cloud`. A new `OrbitFlowModels`
  target, following `OrbitFlowStats`.
- `ModelGrade` for Read aloud ▸ Apple across all three `VoiceGrade` values, including that a
  Premium voice grades above Kokoro.
- Migration: stored defaults from the previous build map as the table above.

Kokoro synthesis and the downloads are not unit-tested — they are network and CoreML. They
are verified by running the app.

## No third rewrite model

An earlier draft of this page offered **Qwen3-1.7B** as a downloadable local rewrite model,
recommended over Apple Intelligence. That was wrong twice over, and the reasoning is
recorded here so it is not rediscovered.

**It is a different kind of thing.** Parakeet and Kokoro are fixed CoreML graphs — one call
in, audio or text out — and FluidAudio already downloads and runs them. An LLM needs its own
runtime (MLX on Metal, not the ANE), a tokenizer, a token-by-token sampling loop with a KV
cache, and a streaming and timeout story. It shares nothing with the other two but the word
"download". The dependency would be `ml-explore/mlx-swift-lm`, which is real and properly
versioned, but it is a new runtime in an app whose only ML dependency today is FluidAudio.

**And it would not be better.** Apple's on-device model is ~3B and built for summarization
and refinement, which is precisely this job; Qwen3-1.7B leads it on reasoning benchmarks,
and turning a rambling voice note into a clean sentence is not reasoning. Paying ~1 GB and a
new runtime to get a smaller model that is worse at the task is the wrong trade.

The one real gap Qwen would fill is the Macs `OnDeviceRewriter.unavailableReason` already
names — not eligible, Apple Intelligence switched off, model still downloading. Those users
have no local rewrite. That is a genuine problem and a much narrower one than "add a local
model", and it should be solved on its own terms if it is solved at all.

## Deliberately not in this project

**Cloud speech to text.** Whisper or Deepgram would fill the greyed segment, but it is the
first time audio would leave the Mac, which cuts against the app's central promise. A
product decision, not a gap in this redesign.

**A "go fully local" bulk action.** Recommended models are tagged per row and downloaded one
at a time, deliberately. Nothing downloads without being asked.
