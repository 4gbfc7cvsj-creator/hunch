import Testing
import CoreGraphics
import Foundation
import HunchCore
@testable import HunchOverlay

@Suite struct PopInTests {
    @Test func testFirstShowAnimates() {
        #expect(PopIn.shouldAnimate(previous: nil, hiddenFor: nil, next: "hello world"))
        #expect(PopIn.shouldAnimate(previous: "", hiddenFor: nil, next: "hello"))
    }
    @Test func testTypingThroughDoesNotAnimate() {
        #expect(!PopIn.shouldAnimate(previous: "hello world", hiddenFor: nil, next: "ello world"))
        #expect(!PopIn.shouldAnimate(previous: "hello world", hiddenFor: nil, next: "world"))
    }
    @Test func testGrowingAndBackspaceDoNotAnimate() {
        #expect(!PopIn.shouldAnimate(previous: "hel", hiddenFor: nil, next: "hello world"))
        #expect(!PopIn.shouldAnimate(previous: "ello", hiddenFor: nil, next: "hello"))
    }
    @Test func testNewTextAnimates() {
        #expect(PopIn.shouldAnimate(previous: "hello world", hiddenFor: nil, next: "goodbye"))
    }
    @Test func testBriefHideIsARedraw() {
        #expect(!PopIn.shouldAnimate(previous: "hello world", hiddenFor: 0.05, next: "ello world"))
        #expect(PopIn.shouldAnimate(previous: "hello world", hiddenFor: 0.05, next: "goodbye"))
    }
    @Test func testLongHideAnimatesEvenIfContinuous() {
        #expect(PopIn.shouldAnimate(previous: "hello world", hiddenFor: 1, next: "ello world"))
    }
    @Test func testReduceMotion() {
        let wiggle = PopInRecipe.preset(.wiggle)
        let calm = PopIn.effective(wiggle, reduceMotion: true)
        #expect(calm.fadeOn && !calm.wiggleOn && calm.fadeMs == wiggle.fadeMs)
        #expect(PopIn.effective(PopInRecipe.preset(.none), reduceMotion: true).isEmpty)
        #expect(PopIn.effective(wiggle, reduceMotion: false) == wiggle)
        #expect(PopIn.effective(PopInRecipe.preset(.typewriter), reduceMotion: true).fadeMs == 150)
    }
    @Test func testTypewriterDurationCapped() {
        let r = PopInRecipe.preset(.typewriter)
        #expect(PopIn.typewriterDuration(r, characters: 100) == 0.45)
        #expect(abs(PopIn.typewriterDuration(r, characters: 2) - 0.044) < 0.0001)
    }
    @Test func testTypewriterShift() {
        #expect(PopIn.typewriterShift(previous: "hello world", next: "hello world, friend") == 0)
        #expect(PopIn.typewriterShift(previous: "hello world", next: "llo world") == 2)
        #expect(PopIn.typewriterShift(previous: "llo world", next: "hello world") == -2)
        #expect(PopIn.typewriterShift(previous: "hello", next: "goodbye") == nil)
    }
    @Test func testRevealResumesWhenStreamGrows() {
        #expect(PopIn.revealResume(previousShown: "The", nextShown: "The best way") == 3)
        #expect(PopIn.revealResume(previousShown: "The best", nextShown: "The best") == nil)
        #expect(PopIn.revealResume(previousShown: "he best", nextShown: "The best") == nil)
        #expect(PopIn.revealResume(previousShown: "The best", nextShown: "best") == nil)
    }
    @Test func testTypewriterRevealCarriesOn() {
        // 5 characters in at 20 ms each; 2 of them typed through leaves 3 of the new text shown.
        #expect(abs(PopIn.typewriterRevealed(elapsed: 0.1, rate: 0.02, shift: 2) - 3) < 0.0001)
        #expect(PopIn.typewriterRevealed(elapsed: 0.02, rate: 0.02, shift: 4) == 0)
    }
    @Test func testDecodeKeepsLockedLettersAndSpaces() {
        let pool = DecodeCharacters.symbols.pool
        let f = PopIn.decodeFrame("hello world", locked: 3, tick: 7, pool: pool)
        #expect(f.count == 11)
        #expect(String(f.prefix(3)) == "hel")
        #expect(f[5] == " ")
        #expect(f[3...].filter { $0 != " " }.allSatisfy { pool.contains($0) })
        #expect(PopIn.decodeFrame("hello world", locked: 3, tick: 7, pool: pool) == f)
        #expect(String(PopIn.decodeFrame("hi", locked: 2, tick: 1, pool: pool)) == "hi")
    }
    @Test func testDecodeScrambleChangesWithTick() {
        let pool = DecodeCharacters.lettersAndNumbers.pool
        let frames = (0..<6).map { String(PopIn.decodeFrame("abcdefgh", locked: 0, tick: $0, pool: pool)) }
        #expect(Set(frames).count > 1)
    }
    @Test func testDecodeRateRespectsCap() {
        var r = PopInRecipe.preset(.decode)
        r.decodeMsPerLetter = 30
        r.decodeMaxMs = 300
        #expect(abs(PopIn.decodeRate(r, characters: 5) - 0.03) < 0.0001)
        #expect(abs(PopIn.decodeRate(r, characters: 20) - 0.015) < 0.0001)
        #expect(abs(PopIn.decodeDuration(r, characters: 20) - 0.3) < 0.0001)
        // Matrix's color fade follows the scramble and adds its own fade at the end.
        #expect(PopIn.sweepRate(r, characters: 20) == PopIn.decodeRate(r, characters: 20))
        #expect(abs(PopIn.colorFadeDuration(r, characters: 20) - 0.65) < 0.0001)
    }
    @Test func testMatrixIsScramblePlusGreenFade() {
        let r = PopInRecipe.preset(.decode)
        #expect(r.decodeOn && r.decodeMsPerLetter == 30 && r.decodeMaxMs == 500 && r.decodeScrambleMs == 25)
        #expect(r.decodeCharacters == .katakana)
        #expect(r.colorFadeOn && r.colorFadeColor == .green && r.colorFadeMs == 350)
    }
    @Test func testColorFadeStandsAlone() {
        var r = PopInRecipe()
        r.colorFadeOn = true
        r.blurOn = true
        r.growOn = true
        #expect(!r.isEmpty && PopIn.isPerLetter(r) && !r.decodeOn)
        r.colorFadeMsPerLetter = 40
        r.colorFadeMaxMs = 400
        r.colorFadeMs = 200
        #expect(abs(PopIn.sweepRate(r, characters: 5) - 0.04) < 0.0001)
        #expect(abs(PopIn.sweepRate(r, characters: 20) - 0.02) < 0.0001)
        #expect(abs(PopIn.colorFadeDuration(r, characters: 20) - 0.6) < 0.0001)
        #expect(abs(PopIn.sweepEnd(r, characters: 20) - 30) < 0.0001)
        #expect(PopIn.totalDuration(r, characters: 20) >= 0.6)
        // At most 0: every letter at once, and the fade still runs to the end.
        r.colorFadeMaxMs = 0
        let rate = PopIn.sweepRate(r, characters: 20)
        #expect(rate > 0)
        let locked = 0.1 / rate
        #expect(abs(PopIn.decodeTint(index: 19, locked: locked, rate: rate, fadeMs: 200) - 0.5) < 0.05)
    }
    @Test func testSweepPaceOrder() {
        var r = PopInRecipe()
        r.particlesOn = true
        #expect(PopIn.sweepPace(r) == .instant && PopIn.isPerLetter(r))
        r.colorFadeOn = true
        #expect(PopIn.sweepPace(r) == .colorFade)
        r.hangOn = true
        r.hangMsPerLetter = 40
        r.hangMaxMs = 400
        #expect(PopIn.sweepPace(r) == .hang)
        #expect(abs(PopIn.sweepRate(r, characters: 20) - 0.02) < 0.0001)
        r.decodeOn = true
        #expect(PopIn.sweepPace(r) == .scramble)
    }
    @Test func testHangPose() {
        var r = PopInRecipe()
        r.hangOn = true
        r.hangDrop = 5
        r.hangBob = 1
        r.hangSwing = 10
        r.hangMs = 1000
        // Not reached yet: hidden, up and tilted.
        let before = PopIn.hangPose(r, t: -0.1)
        #expect(before.alpha == 0 && before.dy == 5 && before.angle == 10)
        // Settled: in place.
        let after = PopIn.hangPose(r, t: 1.2)
        #expect(after.alpha == 1 && after.dy == 0 && after.angle == 0)
        // Mid-way: visible, dipping past its place, still swinging a little.
        let mid = PopIn.hangPose(r, t: 0.8)
        #expect(mid.alpha == 1 && mid.dy < 0 && abs(mid.angle) < 10)
        // The swing shrinks over time.
        let swings = stride(from: 0.0, through: 1.0, by: 0.05).map { abs(PopIn.hangPose(r, t: $0 + 0.0001).angle) }
        #expect(swings.first! > swings.last!)
        #expect(PopIn.hangDuration(r, characters: 10) > 1)
        #expect(PopIn.sweepEnd(r, characters: 10) > 10)
    }
    @Test func testParticleCountsSpreadEvenly() {
        #expect(PopIn.particleCounts("abcd", density: 0.5) == [1, 0, 1, 0])
        #expect(PopIn.particleCounts("ab cd", density: 1) == [1, 1, 0, 1, 1])
        #expect(PopIn.particleCounts("abc", density: 2) == [2, 2, 2])
        #expect(PopIn.particleCounts("abc", density: 0).reduce(0, +) == 0)
    }
    @Test func testParticlePathFallsAndDrifts() {
        let down = PopIn.particlePath(start: .zero, speed: 10, direction: 0, gravity: 20, flutter: 0, phase: 0, life: 1)
        #expect(down.first == .zero && down.count == 17)
        #expect(abs(down.last!.y - -20) < 0.001 && abs(down.last!.x) < 0.001)
        let right = PopIn.particlePath(start: .zero, speed: 10, direction: 90, gravity: 0, flutter: 0, phase: 0, life: 1)
        #expect(abs(right.last!.x - 10) < 0.001 && abs(right.last!.y) < 0.001)
        let up = PopIn.particlePath(start: .zero, speed: 0, direction: 0, gravity: -10, flutter: 2, phase: 1, life: 1)
        #expect(up.last!.y > 0 && up.first == .zero)
    }
    @Test func testGravityPullsAnyWay() {
        let right = PopIn.particlePath(start: .zero, speed: 0, direction: 0, gravity: 20, gravityDirection: 90,
                                       flutter: 0, phase: 0, life: 1)
        #expect(abs(right.last!.x - 10) < 0.001 && abs(right.last!.y) < 0.001)
        let left = PopIn.particlePath(start: .zero, speed: 0, direction: 0, gravity: 20, gravityDirection: -90,
                                      flutter: 0, phase: 0, life: 1)
        #expect(abs(left.last!.x + 10) < 0.001)
        let up = PopIn.particlePath(start: .zero, speed: 0, direction: 0, gravity: 20, gravityDirection: 180,
                                    flutter: 0, phase: 0, life: 1)
        #expect(abs(up.last!.y - 10) < 0.001 && abs(up.last!.x) < 0.001)
        // Flutter sways across the pull: up and down under a sideways wind.
        let windy = PopIn.particlePath(start: .zero, speed: 0, direction: 0, gravity: 0, gravityDirection: 90,
                                       flutter: 3, phase: 0, life: 0.3)
        #expect(windy.contains { abs($0.y) > 1 } && windy.allSatisfy { abs($0.x) < 0.001 })
    }
    @Test func testOldSignedGravityBecomesDirection() throws {
        let old = try JSONDecoder().decode(PopInRecipe.self, from: Data(#"{"particlesOn": true, "particleGravity": -40}"#.utf8))
        #expect(old.particleGravity == 40 && old.particleGravityDirection == 180)
        let down = try JSONDecoder().decode(PopInRecipe.self, from: Data(#"{"particleGravity": 30}"#.utf8))
        #expect(down.particleGravity == 30 && down.particleGravityDirection == 0)
        var r = PopInRecipe.preset(.ember)
        r.particleGravityDirection = -45
        #expect(try JSONDecoder().decode(PopInRecipe.self, from: JSONEncoder().encode(r)) == r)
    }
    @Test func testNewEffectsUseOneNewMechanismEach() throws {
        let neon = PopInRecipe.preset(.neon), ocean = PopInRecipe.preset(.ocean)
        let stardust = PopInRecipe.preset(.stardust), ember = PopInRecipe.preset(.ember)
        func newOnes(_ r: PopInRecipe) -> Int { [r.flickerOn, r.waveOn, r.assembleOn, r.glowOn].filter { $0 }.count }
        #expect(neon.flickerOn && ocean.waveOn && stardust.assembleOn && ember.glowOn)
        for r in [neon, ocean, stardust, ember] {
            // Neon also glows (Flicker + Glow); the others use one new effect each.
            #expect(newOnes(r) == (r == neon ? 2 : 1))
            #expect(PopIn.isPerLetter(r) && PopIn.hasLetterPose(r) && !r.isEmpty)
            #expect(try JSONDecoder().decode(PopInRecipe.self, from: JSONEncoder().encode(r)) == r)
            #expect(PopIn.effective(r, reduceMotion: true).fadeOn)
            #expect(PopIn.totalDuration(r, characters: 20) > 0.3)
        }
        #expect(PopIn.sweepPace(neon) == .flicker && PopIn.sweepPace(ocean) == .wave)
        #expect(PopIn.sweepPace(stardust) == .assemble && PopIn.sweepPace(ember) == .glow)
        #expect(ocean.particleShapes == [.bubble] && ocean.particleGravityDirection == 180)
        #expect(ember.particleGravityDirection == 135)
    }
    @Test func testLetterPosesSettle() {
        var r = PopInRecipe()
        r.flickerOn = true; r.waveOn = true; r.assembleOn = true; r.glowOn = true
        for i in 0..<6 {
            let before = PopIn.letterPose(r, index: i, t: -0.01)
            #expect(before.alpha == 0)
            let after = PopIn.letterPose(r, index: i, t: 5)
            #expect(after == PopIn.LetterPose())
        }
        // Each pose is the same every time for the same letter (redraws don't jump).
        #expect(PopIn.letterPose(r, index: 3, t: 0.2) == PopIn.letterPose(r, index: 3, t: 0.2))
    }
    @Test func testFlickerFlashesThenStaysOn() {
        var r = PopInRecipe()
        r.flickerOn = true; r.flickerCount = 3; r.flickerMs = 450
        for random in [0.0, 100] {
            r.flickerRandomness = random
            for i in 0..<12 {
                let f = PopIn.flickerTiming(r, index: i)
                let samples = stride(from: 0.0005, to: f.length, by: 0.0005).map {
                    PopIn.flickerAlpha(r, index: i, t: f.start + $0)
                }
                // Dark gaps between flashes: one on/off switch for each edge.
                var switches = 0
                for (a, b) in zip(samples, samples.dropFirst()) where (a == 0) != (b == 0) { switches += 1 }
                #expect(switches >= 2 * f.flashes - 1, "letter \(i)")
                #expect(PopIn.flickerAlpha(r, index: i, t: f.start - 0.001) == 0)
                #expect(PopIn.flickerAlpha(r, index: i, t: PopIn.flickerSettle(r, index: i) + 0.001) == 1)
                #expect(PopIn.flickerSettle(r, index: i) <= PopIn.flickerLatestSettle(r) + 1e-9)
            }
        }
    }
    @Test func testNeonGlowsWhileLitThenCools() {
        let r = PopInRecipe.preset(.neon)
        #expect(r.flickerOn && r.glowOn && PopIn.sweepPace(r) == .flicker)
        for i in 0..<10 {
            let f = PopIn.flickerTiming(r, index: i)
            // During the flicker: glowing exactly when a flash is lit.
            for t in stride(from: f.start + 0.001, to: f.start + f.length, by: 0.005) {
                let pose = PopIn.letterPose(r, index: i, t: t)
                #expect((pose.alpha > 0) == (pose.glow == 1))
            }
            // Stays lit at full glow, then cools to none.
            let settle = PopIn.flickerSettle(r, index: i)
            #expect(PopIn.letterPose(r, index: i, t: settle + 0.001).glow > 0.99)
            #expect(PopIn.letterPose(r, index: i, t: settle + r.glowMs / 2000).glow < 0.6)
            #expect(PopIn.letterPose(r, index: i, t: settle + r.glowMs / 1000 + 0.01) == PopIn.LetterPose())
        }
        #expect(PopIn.sweepEnd(r, characters: 10) * PopIn.sweepRate(r, characters: 10)
                >= PopIn.flickerLatestSettle(r) + r.glowMs / 1000)
    }
    @Test func testFlickerIsIrregularOnlyWithRandomness() {
        var r = PopInRecipe()
        r.flickerOn = true; r.flickerCount = 3; r.flickerMs = 450; r.flickerRandomness = 0
        let even = (0..<10).map { PopIn.flickerTiming(r, index: $0) }
        #expect(Set(even.map(\.flashes)) == [3] && even.allSatisfy { $0.start == 0 && abs($0.length - 0.45) < 1e-9 })
        r.flickerRandomness = 100
        let wild = (0..<20).map { PopIn.flickerTiming(r, index: $0) }
        #expect(Set(wild.map(\.flashes)).count >= 3)
        #expect(Set(wild.map { Int($0.length * 100) }).count >= 8)
        // Letters don't light up left to right: some later letter settles before an earlier one.
        let settles = (0..<20).map { Double($0) * 0.035 + PopIn.flickerSettle(r, index: $0) }
        #expect(settles != settles.sorted())
        // The pink holds until each letter stays lit, then fades.
        let i = 4, rate = 0.035
        let lit = PopIn.letterFadeDelay(r, index: i)
        #expect(lit == PopIn.flickerSettle(r, index: i))
        let lockedAtLit = Double(i) + lit / rate
        #expect(PopIn.decodeTint(index: i, locked: lockedAtLit - 0.5, rate: rate, fadeMs: 300, delay: lit) == 1)
        #expect(PopIn.decodeTint(index: i, locked: lockedAtLit + 0.3 / rate, rate: rate, fadeMs: 300, delay: lit) == 0)
    }
    @Test func testAssembleStartsAwayAndArrives() {
        var r = PopInRecipe()
        r.assembleOn = true; r.assembleDistance = 10; r.assembleSpin = 90; r.assembleMs = 500
        let early = PopIn.assemblePose(r, index: 4, t: 0.001)
        #expect(hypot(early.dx, early.dy) > 5 && hypot(early.dx, early.dy) <= 10.01)
        let late = PopIn.assemblePose(r, index: 4, t: 0.45)
        #expect(hypot(late.dx, late.dy) < 0.1 && late.alpha == 1)
        // Letters come from different directions.
        let dirs = (0..<8).map { i -> Double in let p = PopIn.assemblePose(r, index: i, t: 0.001); return atan2(p.dy, p.dx) }
        #expect(Set(dirs.map { Int($0 * 10) }).count > 4)
    }
    @Test func testWaveAndGlowDieAway() {
        var r = PopInRecipe()
        r.waveOn = true; r.waveHeight = 3; r.waveCount = 1.5; r.waveMs = 800
        let heights = stride(from: 0.0, through: 0.8, by: 0.01).map { abs(PopIn.wavePose(r, t: $0 + 0.0001).dy) }
        #expect(heights.max()! > 1.5 && heights.max()! <= 3)
        #expect(heights.last! < 0.05)
        r.glowOn = true; r.glowMs = 1000
        #expect(abs(PopIn.glowPose(r, t: 0.12).glow - 1) < 0.001)
        #expect(PopIn.glowPose(r, t: 0.6).glow < 0.6 && PopIn.glowPose(r, t: 0.99).glow < 0.01)
    }
    @Test func testNewSweepPaceOrderAndMargin() {
        var r = PopInRecipe()
        r.colorFadeOn = true
        r.glowOn = true
        #expect(PopIn.sweepPace(r) == .glow)
        r.flickerOn = true
        #expect(PopIn.sweepPace(r) == .flicker)
        r.waveOn = true
        #expect(PopIn.sweepPace(r) == .wave)
        r.assembleOn = true
        r.assembleMsPerLetter = 50; r.assembleMaxMs = 500
        #expect(PopIn.sweepPace(r) == .assemble && abs(PopIn.sweepRate(r, characters: 20) - 0.025) < 0.0001)
        r.hangOn = true
        #expect(PopIn.sweepPace(r) == .hang)
        var m = PopInRecipe()
        m.assembleOn = true; m.assembleDistance = 20
        #expect(PopIn.margin(m, unit: 1, size: CGSize(width: 100, height: 20)) == 32)
    }
    @MainActor @Test func testEveryParticleShapeFitsItsSize() {
        for shape in ParticleShape.allCases {
            let box = ParticleEmitter.path(shape, size: 10).boundingBoxOfPath
            #expect(!box.isEmpty, "\(shape)")
            #expect(box.minX >= -5.01 && box.maxX <= 5.01 && box.minY >= -5.01 && box.maxY <= 5.01, "\(shape) \(box)")
        }
    }
    @Test func testParticleTrickleLength() {
        var r = PopInRecipe()
        r.particlesOn = true
        #expect(PopIn.particleTrickleSeconds(r) == 0)
        r.particleEmitMs = 2000
        #expect(PopIn.particleTrickleSeconds(r) == 2)
        r.particleEmitMs = PopInRecipe.particleEmitWhileShown
        #expect(PopIn.particleTrickleSeconds(r) == nil)
    }
    @Test func testMarginCoversHangAndParticles() {
        var r = PopInRecipe()
        r.particlesOn = true
        r.particleRoom = 40
        #expect(PopIn.margin(r, unit: 1, size: CGSize(width: 100, height: 20)) == 42)
        r.particlesOn = false
        r.hangOn = true
        r.hangDrop = 5
        r.hangBob = 1
        r.hangSwing = 0
        #expect(PopIn.margin(r, unit: 1, size: CGSize(width: 100, height: 20)) == 8)
        r.hangSwing = 30
        #expect(PopIn.margin(r, unit: 1, size: CGSize(width: 100, height: 20)) == 18)
    }
    @Test func testWisteriaPreset() throws {
        let r = PopInRecipe.preset(.wisteria)
        #expect(r.hangOn && r.particlesOn && r.colorFadeOn && r.colorFadeColor == .custom && r.fadeOn && !r.decodeOn)
        #expect(PopIn.sweepPace(r) == .hang)
        #expect(try JSONDecoder().decode(PopInRecipe.self, from: JSONEncoder().encode(r)) == r)
        #expect(PopIn.effective(r, reduceMotion: true) == { var f = PopInRecipe(); f.fadeOn = true; f.fadeMs = 250; return f }())
        #expect(r.hangMaxMs == 500 && r.hangMs == 400 && r.colorFadeCustom == StoredColor(hex: 0xB88CF2))
        #expect(r.particleShapes == [.petal, .blossom] && r.particleColorB == StoredColor(hex: 0x8554CC))
        let autumn = PopInRecipe.preset(.autumn)
        #expect(autumn.hangOn && autumn.particlesOn && autumn.colorFadeOn && !autumn.fadeOn && autumn.hangMaxMs == 700)
        #expect(autumn.particleSize == 5 && autumn.particleSizeVariation == 50
                && autumn.particleColorA == StoredColor(hex: 0xFF0000) && autumn.colorFadeCustom == StoredColor(hex: 0xFD9219))
        #expect(autumn.colorFadeMs == 500 && autumn.particleShapes == [.petal, .leaf] && autumn.particleDensity == 0.3)
        let winter = PopInRecipe.preset(.winter)
        #expect(winter.hangOn && winter.hangSwing == 16 && winter.hangMaxMs == 700 && !winter.fadeOn)
        #expect(winter.colorFadeCustom == StoredColor(hex: 0xACF1EB) && winter.colorFadeMs == 590)
        #expect(winter.particleShapes == [.snowflake] && winter.particleDensity == 0.2 && winter.particleSize == 7
                && winter.particleSpeed == 6 && winter.particleSpread == 75 && winter.particleFlutter == 7
                && winter.particleSpin == 80 && winter.particleLifeMs == 900 && winter.particleEmitMs == 750
                && winter.particleTrickle == 2 && winter.particleColorB == StoredColor(hex: 0x00FAFF))
        // Saved before the rename: "petal…" keys still load.
        let renamed = try JSONDecoder().decode(PopInRecipe.self, from: Data(
            #"{"petalsOn": true, "petalSize": 9, "petalShapes": ["dot"], "particleRoom": 50}"#.utf8))
        #expect(renamed.particlesOn && renamed.particleSize == 9 && renamed.particleShapes == [.dot] && renamed.particleRoom == 50)
        let old = try JSONDecoder().decode(PopInRecipe.self, from: Data(#"{"fadeOn": true}"#.utf8))
        #expect(!old.hangOn && !old.particlesOn && old.particleShapes == [.petal, .blossom])
    }
    @Test func testOldDecodeColorBecomesColorFade() throws {
        func load(_ json: String) throws -> PopInRecipe {
            try JSONDecoder().decode(PopInRecipe.self, from: Data(json.utf8))
        }
        let bright = try load(#"{"decodeOn": true, "decodeFlash": "bright", "decodeFlashMs": 500}"#)
        #expect(bright.colorFadeOn && bright.colorFadeColor == .bright && bright.colorFadeMs == 500)
        let byDefault = try load(#"{"decodeOn": true}"#)
        #expect(byDefault.colorFadeOn && byDefault.colorFadeColor == .green)
        let off = try load(#"{"decodeOn": true, "decodeFlash": "off"}"#)
        #expect(off.decodeOn && !off.colorFadeOn)
        #expect(!(try load(#"{"fadeOn": true}"#)).colorFadeOn)
        // A saved recipe round-trips, including Color fade switched off next to Scramble.
        var r = PopInRecipe.preset(.decode)
        r.colorFadeOn = false
        r.colorFadeColor = .custom
        r.colorFadeCustom = StoredColor(red: 1, green: 0.5, blue: 0)
        #expect(try JSONDecoder().decode(PopInRecipe.self, from: JSONEncoder().encode(r)) == r)
    }
    @Test func testDecodeTintFadesSmoothly() {
        // Scrambled letters are all scramble color.
        #expect(PopIn.decodeTint(index: 6, locked: 5.2, rate: 0.02, fadeMs: 100) == 1)
        // Just locked: still nearly all of it; halfway through the fade: half; done: none.
        #expect(PopIn.decodeTint(index: 5, locked: 5.01, rate: 0.02, fadeMs: 100) > 0.99)
        #expect(abs(PopIn.decodeTint(index: 0, locked: 2.5, rate: 0.02, fadeMs: 100) - 0.5) < 0.0001)
        #expect(PopIn.decodeTint(index: 0, locked: 6, rate: 0.02, fadeMs: 100) == 0)
        // Each earlier letter is further along, with no jumps between neighbors.
        let tints = (0..<5).map { PopIn.decodeTint(index: $0, locked: 5, rate: 0.02, fadeMs: 100) }
        #expect(tints == tints.sorted())
        #expect(PopIn.decodeTint(index: 0, locked: 3, rate: 0.02, fadeMs: 0) == 0)
    }
    @Test func testDecodeCountsAsAnEffect() {
        #expect(!PopInRecipe.preset(.decode).isEmpty)
        #expect(PopIn.effective(PopInRecipe.preset(.decode), reduceMotion: true).fadeOn)
    }
    @Test func testTotalDurationIsLongestEffect() {
        #expect(PopIn.totalDuration(PopInRecipe.preset(.wiggle), characters: 5) == 0.55)
        #expect(PopIn.totalDuration(PopInRecipe.preset(.none), characters: 5) == 0)
    }
    @Test func testRiseAndDrop() {
        #expect(PopIn.riseKeyframes(distance: 4, bob: 1).values == [-4, 1, -0.3, 0])
        #expect(PopIn.riseKeyframes(distance: -4, bob: 1).values == [4, -1, 0.3, 0])
        #expect(PopIn.riseKeyframes(distance: 4, bob: 0).values == [-4, 0])
    }
    @Test func testWiggleShrinksAndEndsStill() {
        let k = PopIn.wiggleKeyframes(height: 2, count: 2)
        #expect(k.values == [0, 2, -1.5, 1, -0.5, 0])
        #expect(k.times.first == 0 && k.times.last == 1 && k.times.count == k.values.count)
    }
    @Test func testMarginCoversGrowingLarger() {
        var r = PopInRecipe()
        #expect(PopIn.margin(r, unit: 1, size: CGSize(width: 100, height: 20)) == 8)
        r.growOn = true
        r.growFromPercent = 150
        #expect(PopIn.margin(r, unit: 1, size: CGSize(width: 100, height: 20)) == 52)
        r.growFromPercent = 50
        r.slideOn = true
        r.slideDistance = -20
        #expect(PopIn.margin(r, unit: 1, size: CGSize(width: 100, height: 20)) == 22)
    }
    @Test func testOldRecipeKeysDefault() throws {
        let r = try JSONDecoder().decode(PopInRecipe.self, from: Data(#"{"fadeOn": true}"#.utf8))
        #expect(r.fadeOn && r.fadeMs == 120 && !r.slideOn)
    }
    @Test func testRecipeLookup() {
        var a = AppearanceSettings(animation: .fade)
        #expect(a.currentRecipe == PopInRecipe.preset(.fade))
        var tuned = PopInRecipe.preset(.fade)
        tuned.fadeMs = 400
        a.presetTuning["fade"] = tuned
        #expect(a.currentRecipe.fadeMs == 400)
        a.animation = .custom
        #expect(a.currentRecipe == PopInRecipe.customDefault)
    }

    let black = RGBAColor(red: 0, green: 0, blue: 0)
    let accent = RGBAColor(red: 0, green: 0.4, blue: 1)
    let custom = RGBAColor(red: 0.6, green: 0.2, blue: 0.8)

    func color(_ choice: SuggestionColorChoice, _ opacity: Double, text: RGBAColor?, grey: Bool = false) -> RGBAColor {
        PopIn.color(choice: choice, opacity: opacity, textColor: text, greyForced: grey, accent: accent, custom: custom)
    }

    @Test func testDefaultsMatchOriginalLook() {
        #expect(color(.matchText, 0.5, text: black) == RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        #expect(color(.matchText, 0.5, text: nil) == PopIn.grey)
    }
    @Test func testFollowEffectUsesFinalColorElseMatchesText() {
        let pink = RGBAColor(red: 1, green: 0.25, blue: 0.82)
        func follow(_ effect: RGBAColor?, text: RGBAColor? = RGBAColor(red: 0, green: 0, blue: 0), grey: Bool = false) -> RGBAColor {
            PopIn.color(choice: .followEffect, opacity: 0.5, textColor: text, greyForced: grey, accent: accent,
                        custom: custom, effect: effect)
        }
        #expect(follow(pink) == RGBAColor(red: 1, green: 0.25, blue: 0.82, alpha: 0.5))
        #expect(follow(nil) == color(.matchText, 0.5, text: black))
        #expect(follow(nil, text: nil) == PopIn.grey)
        #expect(follow(pink, grey: true) == PopIn.grey)
    }
    @Test func testStylesWithAColorSettleInIt() {
        for style in [PopInAnimation.neon, .ocean, .stardust, .ember, .wisteria, .autumn, .winter] {
            let r = PopInRecipe.preset(style)
            #expect(r.finalColorOn && r.finalColor == r.colorFadeCustom, "\(style)")
        }
        #expect(PopInRecipe.preset(.decode).finalColorOn)
        for style in [PopInAnimation.none, .fade, .materialize, .typewriter, .custom] {
            #expect(!PopInRecipe.preset(style).finalColorOn, "\(style)")
        }
        #expect(!PopInRecipe.customDefault.finalColorOn)
        #expect(AppearanceSettings().color == .followEffect)
        #expect(AppearanceSettings(animation: .neon).effectColor == StoredColor(hex: 0xFF3FD2))
        #expect(AppearanceSettings(animation: .fade).effectColor == nil)
        // A recipe saved before final colors loads without one (the settings migration fills it in).
        let old = try? JSONDecoder().decode(PopInRecipe.self, from: Data(#"{"fadeOn": true}"#.utf8))
        #expect(old?.finalColorOn == false)
    }
    @Test func testGreyForcedWins() {
        #expect(color(.custom, 0.5, text: black, grey: true) == PopIn.grey)
    }
    @Test func testGreyFadesBelowDefault() {
        #expect(abs(color(.grey, 0.25, text: black).alpha - 0.5) < 0.0001)
        #expect(color(.grey, 0.9, text: black).alpha == 1)
    }
    @Test func testSpookyKeepsItsSavedName() throws {
        // Saved as "ghost" before the rename; still loads as Spooky.
        #expect(PopInAnimation.spooky.rawValue == "ghost")
        #expect(try JSONDecoder().decode(PopInAnimation.self, from: Data(#""ghost""#.utf8)) == .spooky)
    }

    @Test func testPawsPreset() throws {
        let r = PopInRecipe.preset(.paws)
        #expect(r.pawsOn && r.imprintOn && !r.particlesOn && !r.finalColorOn)
        #expect(PopIn.sweepPace(r) == .paws && PopIn.isPerLetter(r) && PopIn.hasLetterPose(r))
        #expect(try JSONDecoder().decode(PopInRecipe.self, from: JSONEncoder().encode(r)) == r)
        #expect(PopIn.effective(r, reduceMotion: true).fadeOn && !PopIn.effective(r, reduceMotion: true).pawsOn)
        // Recipes saved before Paws load with both off.
        let old = try JSONDecoder().decode(PopInRecipe.self, from: Data(#"{"fadeOn": true}"#.utf8))
        #expect(!old.pawsOn && !old.imprintOn && old.pawLettersPerStep == 4)
    }

    @Test func testPawStepsRevealLettersInGroups() {
        var r = PopInRecipe.preset(.paws)
        r.pawLettersPerStep = 3; r.pawStepMs = 100; r.pawMaxMs = 4000; r.pawSpread = 0
        let rate = PopIn.sweepRate(r, characters: 9)
        #expect(abs(rate - 0.1 / 3) < 1e-9)
        // Letters 0-2 share the first step, 3-5 the second, each just after its paw lands.
        let starts = (0..<9).map { PopIn.letterStart(r, index: $0, rate: rate) }
        #expect(starts[0] == starts[2] && starts[3] == starts[5] && starts[6] == starts[8])
        #expect(abs(starts[3] - starts[0] - 0.1) < 1e-9 && starts[0] > 0)
        // A letter is hidden until its paw lands.
        #expect(PopIn.letterPose(r, index: 4, t: 0.15 - starts[4]).alpha == 0)
        #expect(PopIn.letterPose(r, index: 4, t: 1).alpha == 1)
        // Without Imprint, a letter appears outright once its paw lands.
        var plain = r
        plain.imprintOn = false
        #expect(PopIn.letterPose(plain, index: 4, t: 0.01).alpha == 1)
        // With a spread, a step's letters ripple out in order, all before the next step lands.
        r.pawSpread = 60
        let spread = (0..<9).map { PopIn.letterStart(r, index: $0, rate: rate) }
        #expect(spread[0] < spread[1] && spread[1] < spread[2] && spread[2] < spread[3])
        #expect(abs(spread[2] - spread[0] - 0.04) < 1e-9 && spread[3] == starts[3])
    }

    @Test func testPawWalkKeepsToItsCap() {
        var r = PopInRecipe.preset(.paws)
        r.pawLettersPerStep = 2; r.pawStepMs = 200; r.pawMaxMs = 600; r.pawTrail = .faded
        // 20 letters = 10 steps; 200 ms each would take 2 s, so steps quicken to 60 ms.
        #expect(PopIn.pawSteps(r, characters: 20) == 10)
        #expect(abs(PopIn.pawStepSeconds(r, characters: 20) - 0.06) < 1e-9)
        let rate = PopIn.sweepRate(r, characters: 20)
        #expect(PopIn.letterStart(r, index: 19, rate: rate) < 0.6)
        // The run covers the last print lingering and fading.
        #expect(PopIn.totalDuration(r, characters: 20) >= 0.54 + (r.pawLingerMs + PopIn.pawFadeMs) / 1000)
    }

    @Test func testPawPrintsAlternateAndFade() {
        var r = PopInRecipe.preset(.paws)
        r.pawLettersPerStep = 2; r.pawStepMs = 100; r.pawMaxMs = 4000; r.pawLingerMs = 300
        r.pawTrail = .faded; r.pawTrailOpacity = 0
        let rate = PopIn.sweepRate(r, characters: 6)
        let mid = PopIn.pawPrints(r, characters: 6, shift: 0, elapsed: 0.25, rate: rate)
        #expect(mid.map(\.first) == [0, 2, 4] && mid.map(\.last) == [1, 3, 5])
        #expect(mid.map(\.above) == [true, false, true] && mid.map(\.color) == [0, 1, 2])
        // Gone once lingered and faded; none before the walk starts.
        #expect(PopIn.pawPrints(r, characters: 6, shift: 0, elapsed: 0.2 + 0.3 + PopIn.pawFadeMs / 1000 + 0.01,
                                rate: rate).isEmpty)
        #expect(PopIn.pawPrints(r, characters: 6, shift: 0, elapsed: -0.01, rate: rate).isEmpty)
        // Typing through the first three letters: the second step's print now stands by letter 0 only.
        let typed = PopIn.pawPrints(r, characters: 3, shift: 3, elapsed: 0.25, rate: rate)
        #expect(typed.map(\.first) == [0, 1] && typed.map(\.last) == [0, 2])
    }

    @Test func testFourPawsAtMost() {
        var r = PopInRecipe.preset(.paws)
        r.pawLettersPerStep = 1; r.pawStepMs = 100; r.pawMaxMs = 4000; r.pawTrail = .fourPaws
        let rate = PopIn.sweepRate(r, characters: 12)
        for ms in stride(from: 0, through: 1600, by: 5) {
            let shown = PopIn.pawPrints(r, characters: 12, shift: 0, elapsed: Double(ms) / 1000, rate: rate)
                .filter { $0.alpha > 0.001 }
            #expect(shown.count <= PopIn.pawCount)
        }
        // The oldest has just gone as the fifth lands; every print is gone once the cat walks off.
        let fifth = PopIn.pawPrints(r, characters: 12, shift: 0, elapsed: 0.4, rate: rate)
        #expect(!fifth.contains { $0.first == 0 } && fifth.contains { $0.first == 1 })
        #expect(PopIn.pawPrints(r, characters: 12, shift: 0, elapsed: 1.11 + 0.4, rate: rate).isEmpty)
    }

    @Test func testFadedTrailStays() {
        var r = PopInRecipe.preset(.paws)
        r.pawTrail = .faded; r.pawTrailOpacity = 30; r.pawLingerMs = 200
        let walkOn = PopIn.pawPrints(r, characters: 8, shift: 0, elapsed: 60, rate: PopIn.sweepRate(r, characters: 8))
        #expect(walkOn.count == 2 && walkOn.allSatisfy { abs($0.alpha - 0.3) < 1e-9 })
    }

    @Test func testWalkKeepsItsStepsAsWordsStreamIn() {
        var r = PopInRecipe.preset(.paws)
        r.pawLettersPerStep = 4; r.pawStepMs = 100; r.pawMaxMs = 4000
        var walk = PawWalk(r, characters: 6)
        walk.advance(to: 0.15, characters: 6)
        // Two steps: 0-3, then the 2 letters there were.
        #expect(walk.steps.map(\.first) == [0, 4] && walk.steps.map(\.last) == [3, 5])
        let before = walk.steps
        // More words arrive: landed steps keep their letters and times; the cat steps on, in step.
        walk.advance(to: 0.18, characters: 14)
        #expect(Array(walk.steps.prefix(2)) == before && walk.steps.count == 2)
        walk.advance(to: 0.2, characters: 14)
        #expect(walk.steps.count == 3 && walk.steps[2].first == 6 && abs(walk.steps[2].land - 0.2) < 1e-9)
        // Having caught up, it waits, then steps on new letters as soon as they come.
        walk.advance(to: 1, characters: 14)
        #expect(walk.next == 14)
        walk.advance(to: 2, characters: 14)
        walk.advance(to: 2.5, characters: 17)
        #expect(abs(walk.steps.last!.land - 2.5) < 1e-9 && walk.steps.last!.ordinal == walk.steps.count - 1)
        #expect(walk.letterStart(r, index: 16) != nil && walk.letterStart(r, index: 17) == nil)
        // Typing through 5 letters: the first step goes, the second now starts at letter 0.
        walk.dropFront(5)
        #expect(walk.steps.first?.first == 0 && walk.steps.first?.last == 0 && walk.steps.first?.cut == 1)
    }

    /// Words streaming in at uneven times, drawn at 60 frames a second, as the overlay does: a print
    /// never moves, re-lands or jumps in strength, and letters only ever come in, never go back.
    @Test func testStreamingWalkIsSmooth() {
        for trail in PawTrail.allCases {
            var r = PopInRecipe.preset(.paws)
            r.pawLettersPerStep = 8; r.pawStepMs = 200; r.pawMaxMs = 600; r.pawSize = 16
            r.pawLingerMs = 1000; r.pawTrail = trail
            // (seconds, letters there): a first word, then chunks, a pause, and a late one.
            let arrivals: [(TimeInterval, Int)] = [(0, 5), (0.09, 11), (0.13, 19), (0.4, 27), (1.6, 34), (1.62, 41)]
            var walk = PawWalk(r, characters: 5)
            var seen: [Int: (first: Int, last: Int, alpha: Double)] = [:]
            var shown: [Int: Double] = [:]
            for frame in 0...240 {
                let time = Double(frame) / 60
                let count = arrivals.last { $0.0 <= time }!.1
                walk.advance(to: time, characters: count)
                for (i, step) in walk.steps.enumerated() {
                    let print = PopIn.pawPrint(r, first: step.first, last: step.last, ordinal: step.ordinal,
                                               age: time - step.land, step: walk.step)
                    let alpha = print?.alpha ?? 0
                    if let old = seen[i] {
                        #expect(old.first == step.first && old.last == step.last)
                        #expect(abs(alpha - old.alpha) < 0.45, "print \(i) jumped at frame \(frame)")
                    }
                    seen[i] = (step.first, step.last, alpha)
                }
                for i in 0..<count {
                    let t = walk.letterStart(r, index: i).map { time - $0 } ?? -1
                    let a = PopIn.letterPose(r, index: i, t: t).alpha
                    if let old = shown[i] { #expect(a >= old - 1e-9, "letter \(i) went back at frame \(frame)") }
                    shown[i] = a
                }
            }
            #expect(walk.next == 41 && shown.values.allSatisfy { $0 == 1 })
            if trail == .fourPaws {
                #expect(walk.prints(r, at: 4).isEmpty)
            }
        }
    }

    @Test func testImprintStampsDown() {
        var r = PopInRecipe()
        r.imprintOn = true; r.imprintFromPercent = 150; r.imprintDepth = 80; r.imprintMs = 1000
        #expect(PopIn.sweepPace(r) == .imprint)
        let early = PopIn.imprintPose(r, t: 0.01)
        #expect(early.scaleY > 1.4 && early.inset == 0)
        let impact = PopIn.imprintPose(r, t: 0.4)
        #expect(impact.scaleY < 1 && impact.scaleX > 1 && abs(impact.inset - 0.8) < 1e-9)
        #expect(PopIn.imprintPose(r, t: 1) == (1, 1, 1, 0))
        #expect(PopIn.margin(r, unit: 1, size: CGSize(width: 100, height: 20)) >= 12)
    }

    @Test func testGhostPreset() throws {
        let r = PopInRecipe.preset(.spooky)
        #expect(r.rippleOn && r.glowOn && r.colorFadeOn && r.particlesOn && !r.phaseOn)
        #expect(r.particleShapes == [.wisp, .mist] && r.particleGravityDirection == 180 && r.particleEmitMs > 0)
        #expect(PopIn.sweepPace(r) == .ripple && PopIn.isPerLetter(r) && PopIn.hasLetterPose(r))
        // Flashes pale green, settles in lavender.
        #expect(r.colorFadeCustom == StoredColor(hex: 0x94DE98))
        #expect(r.finalColorOn && r.finalColor == StoredColor(hex: 0x988EDB))
        #expect(try JSONDecoder().decode(PopInRecipe.self, from: JSONEncoder().encode(r)) == r)
        #expect(PopIn.effective(r, reduceMotion: true).fadeOn && !PopIn.effective(r, reduceMotion: true).rippleOn)
        // The run lasts until the ripple has calmed, the color has faded and the glow has cooled.
        #expect(PopIn.letterTailMs(r) == max(r.colorFadeMs, r.rippleMs, r.glowMs))
        #expect(PopIn.totalDuration(r, characters: 20) > 1)
        // Recipes saved before Phase and Ripple load with both off.
        let old = try JSONDecoder().decode(PopInRecipe.self, from: Data(#"{"fadeOn": true}"#.utf8))
        #expect(!old.phaseOn && !old.rippleOn && old.phaseEchoes == 3)
    }
    @Test func testPhaseAndRipplePoses() {
        var r = PopInRecipe()
        r.phaseOn = true
        let before = PopIn.letterPose(r, index: 0, t: -0.01)
        #expect(before.alpha == 0 && before.echoAlpha == 0)
        // Early on only the afterimages show, at nearly their starting size.
        let early = PopIn.letterPose(r, index: 0, t: 0.15 * r.phaseMs / 1000)
        #expect(early.alpha == 0 && early.echoAlpha > 0.5 && early.echo > 0.85)
        // Later the letter is in and the afterimages have merged into it.
        let late = PopIn.letterPose(r, index: 0, t: 0.8 * r.phaseMs / 1000)
        #expect(late.alpha == 1 && late.echo == 0 && late.echoAlpha < 0.1)
        #expect(PopIn.letterPose(r, index: 0, t: 5) == PopIn.LetterPose())
        #expect(PopIn.margin(r, unit: 1, size: CGSize(width: 100, height: 20)) > 8)

        var w = PopInRecipe()
        w.rippleOn = true; w.rippleStrength = 2
        #expect(PopIn.sweepPace(w) == .ripple)
        let start = PopIn.letterPose(w, index: 3, t: 0.01)
        #expect(start.ripple > 1.9 && start.alpha < 0.1)
        let mid = PopIn.letterPose(w, index: 3, t: w.rippleMs / 2000)
        #expect(mid.ripple > 0 && mid.ripple < 1 && mid.alpha == 1)
        // Neighbors don't wave in step, and a letter's wave is the same on every redraw.
        #expect(PopIn.letterPose(w, index: 4, t: 0.2).ripplePhase != mid.ripplePhase)
        #expect(PopIn.letterPose(w, index: 3, t: 0.2) == PopIn.letterPose(w, index: 3, t: 0.2))
        #expect(PopIn.letterPose(w, index: 3, t: 5) == PopIn.LetterPose())
    }
    @Test func testAccentAndCustomUseOpacity() {
        #expect(color(.accent, 0.7, text: black) == RGBAColor(red: 0, green: 0.4, blue: 1, alpha: 0.7))
        #expect(color(.custom, 0.3, text: nil) == RGBAColor(red: 0.6, green: 0.2, blue: 0.8, alpha: 0.3))
    }
}
