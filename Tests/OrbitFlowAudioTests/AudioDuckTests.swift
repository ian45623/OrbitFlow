import Testing
@testable import OrbitFlowAudio

/// Ducking is a promise to put the user's volume back exactly as it was — unless they
/// changed it themselves while the microphone was open, in which case their choice wins.

@Test("Ducking drops the volume to a fifth of where it was")
func ducksToAFifth() throws {
    var duck = AudioDuck()
    let ducked = duck.duck(from: 0.8, muted: false)
    let level = try #require(ducked)
    #expect(abs(level - 0.16) < 0.0001)
}

@Test("A silent device is left alone")
func silentDeviceUntouched() {
    var duck = AudioDuck()
    #expect(duck.duck(from: 0, muted: false) == nil)
    #expect(duck.restore(current: 0) == nil)
}

@Test("A muted device is left alone")
func mutedDeviceUntouched() {
    var duck = AudioDuck()
    #expect(duck.duck(from: 0.8, muted: true) == nil)
    #expect(duck.restore(current: 0.8) == nil)
}

@Test("Restoring puts back the level from before the duck")
func restoresOriginal() {
    var duck = AudioDuck()
    _ = duck.duck(from: 0.8, muted: false)
    #expect(duck.restore(current: 0.16) == 0.8)
}

@Test("A device that rounds the ducked level still counts as untouched")
func toleratesQuantisation() {
    var duck = AudioDuck()
    _ = duck.duck(from: 0.8, muted: false)
    #expect(duck.restore(current: 0.1625) == 0.8)
}

@Test("Moving the slider mid-dictation keeps the user's level")
func userChangeWins() {
    var duck = AudioDuck()
    _ = duck.duck(from: 0.8, muted: false)
    #expect(duck.restore(current: 0.5) == nil)
}

@Test("Ducking twice keeps the first saved level")
func doubleDuckKeepsOriginal() {
    var duck = AudioDuck()
    _ = duck.duck(from: 0.8, muted: false)
    #expect(duck.duck(from: 0.16, muted: false) == nil)
    #expect(duck.restore(current: 0.16) == 0.8)
}

@Test("Restoring without a duck does nothing")
func restoreWithoutDuck() {
    var duck = AudioDuck()
    #expect(duck.restore(current: 0.5) == nil)
}

@Test("Restoring clears the duck, so a second restore does nothing")
func restoreIsOneShot() {
    var duck = AudioDuck()
    _ = duck.duck(from: 0.8, muted: false)
    _ = duck.restore(current: 0.16)
    #expect(duck.restore(current: 0.16) == nil)
}
