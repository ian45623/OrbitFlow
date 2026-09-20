import Testing

@testable import OrbitFlowModels

struct ModelGradeTests {

    // MARK: - Per-option grades

    @Test("Apple transcription is the fast, modest option")
    func speechApple() {
        let g = ModelGrade.grade(job: .speech, source: .apple, voice: .standard)
        #expect(g?.quality == .good)
        #expect(g?.speed == .instant)
    }

    @Test("Parakeet trades a little speed for accuracy")
    func speechParakeet() {
        let g = ModelGrade.grade(job: .speech, source: .local, voice: .standard)
        #expect(g?.quality == .excellent)
        #expect(g?.speed == .fast)
    }

    /// Apple Intelligence is a ~3B model built for refinement, which is this exact job.
    /// Grading it Good would push people to the cloud for no reason this app believes in.
    @Test("Apple Intelligence grades excellent, not good")
    func rewriteApple() {
        let g = ModelGrade.grade(job: .rewrite, source: .apple, voice: .standard)
        #expect(g?.quality == .excellent)
        #expect(g?.speed == .instant)
    }

    /// There is no local rewrite model: for rewriting, Apple Intelligence *is* local.
    @Test("Rewrite has no local option")
    func rewriteLocalIsNil() {
        #expect(ModelGrade.grade(job: .rewrite, source: .local, voice: .standard) == nil)
    }

    /// Orbit Flow has never sent audio anywhere.
    @Test("Speech has no cloud option")
    func speechCloudIsNil() {
        #expect(ModelGrade.grade(job: .speech, source: .cloud, voice: .standard) == nil)
    }

    // MARK: - Apple read-aloud is the computed one

    @Test("Apple read-aloud grade follows the selected voice")
    func readAloudFollowsVoice() {
        #expect(ModelGrade.grade(job: .readAloud, source: .apple, voice: .standard)?.quality == .good)
        #expect(ModelGrade.grade(job: .readAloud, source: .apple, voice: .enhanced)?.quality == .excellent)
        #expect(ModelGrade.grade(job: .readAloud, source: .apple, voice: .premium)?.quality == .exceptional)
    }

    /// True, and worth telling people: a Premium voice really is better than Kokoro.
    @Test("A premium Apple voice outranks Kokoro")
    func premiumBeatsKokoro() {
        let apple = ModelGrade.grade(job: .readAloud, source: .apple, voice: .premium)!
        let kokoro = ModelGrade.grade(job: .readAloud, source: .local, voice: .standard)!
        #expect(apple.quality.rawValue > kokoro.quality.rawValue)
    }

    /// The voice only moves the Apple grade. Kokoro's quality has nothing to do with
    /// which system voice happens to be selected.
    @Test("Voice does not affect Kokoro or ElevenLabs")
    func voiceOnlyAffectsApple() {
        for voice in [VoiceGrade.standard, .enhanced, .premium] {
            #expect(ModelGrade.grade(job: .readAloud, source: .local, voice: voice)?.quality == .excellent)
            #expect(ModelGrade.grade(job: .readAloud, source: .cloud, voice: voice)?.quality == .exceptional)
        }
    }

    // MARK: - The readout

    @Test("All Apple, standard voice: good and instant")
    func readoutAllApple() {
        let r = ModelGrade.readout(
            speech: .apple, rewrite: .apple, readAloud: .apple, voice: .standard,
            readAloudAIOverrideIsCloud: false
        )
        #expect(r.quality == .good)
        #expect(r.speed == .instant)
        #expect(r.leavesMac == false)
        #expect(r.speedFraction == 1.0)
    }

    @Test("The recommended local setup reads excellent and fast")
    func readoutRecommended() {
        let r = ModelGrade.readout(
            speech: .local, rewrite: .apple, readAloud: .local, voice: .standard,
            readAloudAIOverrideIsCloud: false
        )
        #expect(r.quality == .excellent)
        #expect(r.speed == .fast)
        #expect(r.leavesMac == false)
    }

    @Test("Any cloud job means work leaves the Mac")
    func readoutLeavesMac() {
        #expect(ModelGrade.readout(
            speech: .apple, rewrite: .cloud, readAloud: .apple, voice: .standard,
            readAloudAIOverrideIsCloud: false
        ).leavesMac)
        #expect(ModelGrade.readout(
            speech: .apple, rewrite: .apple, readAloud: .cloud, voice: .standard,
            readAloudAIOverrideIsCloud: false
        ).leavesMac)
    }

    /// M4: Rewrite set to Apple, read-aloud engine set to Apple — but an AI reading mode
    /// points its own override at a cloud provider. Nothing in `pairs` sees this call, so
    /// without the extra flag the readout would print "This Mac" while a summary is
    /// uploaded — the exact false locality claim this parameter exists to close.
    @Test("A cloud read-aloud AI override leaves the Mac even when every job reads Apple")
    func readoutReadAloudOverrideLeavesMac() {
        let r = ModelGrade.readout(
            speech: .apple, rewrite: .apple, readAloud: .apple, voice: .standard,
            readAloudAIOverrideIsCloud: true
        )
        #expect(r.leavesMac)
    }

    /// The flag only matters when it's true — it must never manufacture a caution dot for
    /// a fully local setup.
    @Test("No override flag means the readout can still claim This Mac")
    func readoutNoOverrideStaysLocal() {
        let r = ModelGrade.readout(
            speech: .local, rewrite: .apple, readAloud: .local, voice: .standard,
            readAloudAIOverrideIsCloud: false
        )
        #expect(r.leavesMac == false)
    }

    @Test("Fractions are the mean over three")
    func readoutFractions() {
        // speech local 2 + rewrite apple 2 + readAloud apple 1 = 5/9
        let r = ModelGrade.readout(
            speech: .local, rewrite: .apple, readAloud: .apple, voice: .standard,
            readAloudAIOverrideIsCloud: false
        )
        #expect(abs(r.qualityFraction - 5.0 / 9.0) < 0.0001)
    }

    /// An unavailable source must never crash the readout — it grades as if Apple, which
    /// is what the disabled segment prevents the user reaching anyway.
    @Test("An impossible source falls back rather than trapping")
    func readoutImpossibleSource() {
        let r = ModelGrade.readout(
            speech: .cloud, rewrite: .local, readAloud: .apple, voice: .standard,
            readAloudAIOverrideIsCloud: false
        )
        #expect(r.quality == .good)
    }
}
