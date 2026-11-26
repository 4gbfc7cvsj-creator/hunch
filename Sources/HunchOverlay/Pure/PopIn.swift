import Foundation
import HunchCore

/// Pure rules behind Settings → Appearance: when a suggestion animates in, and its color.
public enum PopIn {
    /// A ghost hidden for less than this and back with continuous text was only redrawn (typing
    /// through it, accepting a word), not replaced.
    public static let redrawGap: TimeInterval = 0.25

    /// Whether `next` is new text that should play the pop-in. Not when it continues what was shown:
    /// typed through (a tail of it), grown (it extends it) or backspaced into (it ends with it).
    /// `hiddenFor` is how long the ghost has been hidden (nil = still showing).
    public static func shouldAnimate(previous: String?, hiddenFor: TimeInterval?, next: String) -> Bool {
        guard let previous, !previous.isEmpty else { return true }
        if let hiddenFor, hiddenFor >= redrawGap { return true }
        let continuous = previous.hasSuffix(next) || next.hasPrefix(previous) || next.hasSuffix(previous)
        return !continuous
    }

    /// With Reduce Motion on, anything that moves becomes a plain fade (at the recipe's fade length,
    /// else 150 ms).
    public static func effective(_ recipe: PopInRecipe, reduceMotion: Bool) -> PopInRecipe {
        guard reduceMotion, !recipe.isEmpty else { return recipe }
        var fade = PopInRecipe()
        fade.fadeOn = true
        fade.fadeMs = recipe.fadeOn ? recipe.fadeMs : 150
        return fade
    }

    /// The typewriter's whole reveal, in seconds.
    public static func typewriterDuration(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        min(recipe.typewriterMaxMs, max(1, recipe.typewriterMsPerCharacter) * Double(max(1, characters))) / 1000
    }

    /// The longest effect, in seconds.
    public static func totalDuration(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        var ms: [Double] = [0]
        if recipe.fadeOn { ms.append(recipe.fadeMs) }
        if recipe.slideOn { ms.append(recipe.slideMs) }
        if recipe.riseOn { ms.append(recipe.riseMs) }
        if recipe.wiggleOn { ms.append(recipe.wiggleMs) }
        if recipe.blurOn { ms.append(recipe.blurMs) }
        if recipe.growOn { ms.append(recipe.growMs) }
        let typing = recipe.typewriterOn ? typewriterDuration(recipe, characters: characters) : 0
        return max(ms.max()! / 1000, typing, perLetterDuration(recipe, characters: characters))
    }

    /// The per-letter effects' whole run (sweep plus the last letter's own effects), in seconds; 0 when
    /// none is on.
    public static func perLetterDuration(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        guard isPerLetter(recipe), recipe.decodeOn || letterTailMs(recipe) > 0 || recipe.colorFadeOn else { return 0 }
        let sweep = sweepRate(recipe, characters: characters) * Double(max(1, characters))
        return sweep + letterTailMs(recipe) / 1000
    }

    /// How long one letter's own effects run after the sweep reaches it, in ms.
    static func letterTailMs(_ r: PopInRecipe, paws: Bool = true) -> Double {
        var ms = letterFadeMs(r)
        if r.hangOn { ms = max(ms, r.hangMs) }
        // A flickering letter's color fade waits until it stays lit.
        if r.flickerOn { ms = max(ms, flickerLatestSettle(r) * 1000 + letterFadeMs(r)) }
        if r.waveOn { ms = max(ms, r.waveMs) }
        if r.assembleOn { ms = max(ms, r.assembleMs) }
        if r.phaseOn { ms = max(ms, r.phaseMs) }
        if r.rippleOn { ms = max(ms, r.rippleMs) }
        if r.imprintOn { ms = max(ms, r.imprintMs) }
        // The last paw's letters ripple out, and its print lingers and fades.
        if paws, r.pawsOn {
            let step = max(10, r.pawStepMs)
            ms = max(ms, pawPressMs + min(1, max(0, r.pawSpread / 100)) * step + (r.imprintOn ? r.imprintMs : 0))
            ms = max(ms, pawPressMs + (r.pawTrail == .fourPaws
                ? Double(pawCount) * step : max(0, r.pawLingerMs) + pawFadeMs))
        }
        if r.glowOn {
            // With Flicker, the glow cools from when the letter stays lit; with Phase, from when it
            // starts to surface.
            ms = max(ms, r.glowMs + glowDelay(r) * 1000)
        }
        return max(0, ms)
    }

    // MARK: Scramble and color fade (per-letter effects)

    /// Whether the ghost is drawn letter by letter while the pop-in runs.
    public static func isPerLetter(_ recipe: PopInRecipe) -> Bool {
        recipe.decodeOn || recipe.colorFadeOn || recipe.hangOn || recipe.particlesOn || hasLetterPose(recipe)
    }

    /// Whether letters move, flicker or glow one by one (anything `letterPose` draws).
    public static func hasLetterPose(_ r: PopInRecipe) -> Bool {
        r.hangOn || r.flickerOn || r.waveOn || r.assembleOn || r.glowOn || r.phaseOn || r.rippleOn
            || r.pawsOn || r.imprintOn
    }

    /// Which effect paces the left-to-right sweep that the per-letter effects share.
    public enum SweepPace: Equatable, Sendable {
        case paws, scramble, hang, phase, ripple, imprint, assemble, wave, flicker, glow, colorFade, instant

        /// The effect's name in Settings.
        public var name: String {
            switch self {
            case .paws: "Paw walk"
            case .scramble: "Scramble"
            case .hang: "Hang"
            case .phase: "Phase"
            case .ripple: "Ripple"
            case .imprint: "Imprint"
            case .assemble: "Assemble"
            case .wave: "Wave"
            case .flicker: "Flicker"
            case .glow: "Glow"
            case .colorFade: "Color fade"
            case .instant: "nothing"
            }
        }
    }

    /// The first switched-on effect in `SweepPace` order leads; Particles alone appear all at once.
    /// Paw walk always leads: letters wait for their paw.
    public static func sweepPace(_ recipe: PopInRecipe) -> SweepPace {
        if recipe.pawsOn { return .paws }
        if recipe.decodeOn { return .scramble }
        if recipe.hangOn { return .hang }
        if recipe.phaseOn { return .phase }
        if recipe.rippleOn { return .ripple }
        if recipe.imprintOn { return .imprint }
        if recipe.assembleOn { return .assemble }
        if recipe.waveOn { return .wave }
        if recipe.flickerOn { return .flicker }
        if recipe.glowOn { return .glow }
        if recipe.colorFadeOn { return .colorFade }
        return .instant
    }

    /// Seconds between letters in the shared sweep. An "at most" of 0 means every letter at once,
    /// kept just above 0 so per-letter timing still works.
    public static func sweepRate(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        func rate(_ perLetter: Double, _ maxMs: Double) -> TimeInterval {
            max(0.0001, min(max(1, perLetter), maxMs / Double(max(1, characters))) / 1000)
        }
        switch sweepPace(recipe) {
        case .paws: return pawStepSeconds(recipe, characters: characters) / Double(pawLetters(recipe))
        case .scramble: return decodeRate(recipe, characters: characters)
        case .hang: return rate(recipe.hangMsPerLetter, recipe.hangMaxMs)
        case .phase: return rate(recipe.phaseMsPerLetter, recipe.phaseMaxMs)
        case .ripple: return rate(recipe.rippleMsPerLetter, recipe.rippleMaxMs)
        case .imprint: return rate(recipe.imprintMsPerLetter, recipe.imprintMaxMs)
        case .assemble: return rate(recipe.assembleMsPerLetter, recipe.assembleMaxMs)
        case .wave: return rate(recipe.waveMsPerLetter, recipe.waveMaxMs)
        case .flicker: return rate(recipe.flickerMsPerLetter, recipe.flickerMaxMs)
        case .glow: return rate(recipe.glowMsPerLetter, recipe.glowMaxMs)
        case .colorFade: return rate(recipe.colorFadeMsPerLetter, recipe.colorFadeMaxMs)
        case .instant: return 0.0001
        }
    }

    /// Hang's whole run: the sweep plus the last letter settling, in seconds.
    public static func hangDuration(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        sweepRate(recipe, characters: characters) * Double(max(1, characters)) + max(0, recipe.hangMs) / 1000
    }

    /// One letter's Hang pose `t` seconds after the sweep reaches it: how visible it is, how far
    /// above its place (points, up = positive) and its tilt (degrees, hinged at its top).
    public static func hangPose(_ recipe: PopInRecipe, t: TimeInterval) -> (alpha: Double, dy: Double, angle: Double) {
        let length = max(0.01, recipe.hangMs / 1000)
        guard t > 0 else { return (0, recipe.hangDrop, recipe.hangSwing) }
        let p = min(1, t / length)
        guard p < 1 else { return (1, 0, 0) }
        func smooth(_ x: Double) -> Double { let x = min(1, max(0, x)); return x * x * (3 - 2 * x) }
        // Drops into place over the first 60 %, dips by the bob, comes back up.
        var dy = recipe.hangDrop * (1 - smooth(p / 0.6))
        if p > 0.6 { dy -= recipe.hangBob * sin(.pi * (p - 0.6) / 0.4) }
        // A pendulum that starts at full tilt and dies out by the end (1.75 swings).
        let angle = recipe.hangSwing * pow(1 - p, 2) * cos(2 * .pi * 1.75 * p)
        return (smooth(p / 0.3), dy, angle)
    }

    /// One letter's look while the per-letter effects run: visibility, offset (points, up =
    /// positive), tilt hinged at its top and spin about its middle (degrees), and glow (0...1).
    public struct LetterPose: Equatable, Sendable {
        public var alpha = 1.0
        public var dx = 0.0
        public var dy = 0.0
        public var tilt = 0.0
        public var spin = 0.0
        public var glow = 0.0
        /// Phase: how far the afterimages are from merging (1 = at their starting size, 0 = merged),
        /// and how visible they are.
        public var echo = 0.0
        public var echoAlpha = 0.0
        /// Ripple: how far the warp bends the letter (points) and where the wave is (radians).
        public var ripple = 0.0
        public var ripplePhase = 0.0
        /// Imprint: the letter's size (1 = its own), scaled about the middle of its baseline, and how
        /// pressed into the page it looks (0...1).
        public var scaleX = 1.0
        public var scaleY = 1.0
        public var inset = 0.0
        public init() {}
    }

    /// Letter `index`'s pose `t` seconds after the sweep reaches it, from every pose effect that's on
    /// (they combine: visibilities multiply, offsets and turns add up).
    public static func letterPose(_ r: PopInRecipe, index: Int, t: TimeInterval) -> LetterPose {
        var pose = LetterPose()
        if r.hangOn {
            let h = hangPose(r, t: t)
            pose.alpha *= h.alpha
            pose.dy += h.dy
            pose.tilt += h.angle
        }
        if r.flickerOn { pose.alpha *= flickerAlpha(r, index: index, t: t) }
        if r.waveOn {
            let w = wavePose(r, t: t)
            pose.alpha *= w.alpha
            pose.dy += w.dy
        }
        if r.assembleOn {
            let a = assemblePose(r, index: index, t: t)
            pose.alpha *= a.alpha
            pose.dx += a.dx
            pose.dy += a.dy
            pose.spin += a.spin
        }
        if r.phaseOn {
            let ph = phasePose(r, t: t)
            pose.alpha *= ph.alpha
            pose.echo = ph.spread
            pose.echoAlpha = ph.echoAlpha
        }
        if r.imprintOn {
            let im = imprintPose(r, t: t)
            pose.alpha *= im.alpha
            pose.scaleX *= im.scaleX
            pose.scaleY *= im.scaleY
            pose.inset = im.inset
        } else if r.pawsOn {
            // Without Imprint, a letter simply appears once its paw has landed.
            pose.alpha *= t > 0 ? 1 : 0
        }
        if r.rippleOn {
            let rp = ripplePose(r, index: index, t: t)
            pose.alpha *= rp.alpha
            pose.ripple = rp.strength
            pose.ripplePhase = rp.phase
        }
        if r.glowOn {
            if r.phaseOn && !r.flickerOn {
                // The aura lights as the letter starts to surface; the letter's own visibility is Phase's.
                pose.glow = glowPose(r, t: t - glowDelay(r)).glow
            } else if r.flickerOn {
                // A neon tube: glows whenever a flash is lit, then cools once the letter stays on.
                let settle = flickerSettle(r, index: index)
                if t < settle {
                    pose.glow = pose.alpha > 0 ? 1 : 0
                } else {
                    pose.glow = 1 - smooth((t - settle) / max(0.01, r.glowMs / 1000))
                }
            } else {
                let g = glowPose(r, t: t)
                pose.alpha *= g.alpha
                pose.glow = g.glow
            }
        }
        return pose
    }

    private static func smooth(_ x: Double) -> Double { let x = min(1, max(0, x)); return x * x * (3 - 2 * x) }

    /// A stable pseudo-random number in 0..<1 for (letter, salt): the same letter always gets the
    /// same scatter and flicker pattern, so redraws don't jump.
    static func letterRandom(_ index: Int, _ salt: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: index &* 2_654_435_761) ^ UInt64(truncatingIfNeeded: salt &* 40_503)
        h ^= h >> 16
        h = h &* 0x45d9f3b
        h ^= h >> 16
        h = h &* 0x45d9f3b
        h ^= h >> 16
        return Double(h % 10_000) / 10_000
    }

    /// One letter's flicker: seconds after the sweep reaches it that it starts, how long it
    /// flickers, and how many flashes. With randomness on, letters start late by up to 80 % of
    /// the length, run 50-170 % of it, and flash up to 2 more or fewer times, so they don't
    /// light up in step.
    public static func flickerTiming(_ r: PopInRecipe, index: Int) -> (start: TimeInterval, length: TimeInterval, flashes: Int) {
        let k = min(1, max(0, r.flickerRandomness / 100))
        let base = max(0.01, r.flickerMs / 1000)
        let start = k * 0.8 * base * letterRandom(index, 201)
        let length = base * (1 + k * (1.2 * letterRandom(index, 202) - 0.5))
        let extra = (k * (4 * letterRandom(index, 203) - 2)).rounded()
        return (start, length, max(1, Int(r.flickerCount.rounded() + extra)))
    }

    /// Seconds after the sweep reaches a letter that it stays lit for good.
    public static func flickerSettle(_ r: PopInRecipe, index: Int) -> TimeInterval {
        let f = flickerTiming(r, index: index)
        return f.start + f.length
    }

    /// The latest any letter can stay lit, after the sweep reaches it.
    static func flickerLatestSettle(_ r: PopInRecipe) -> TimeInterval {
        let k = min(1, max(0, r.flickerRandomness / 100))
        return max(0.01, r.flickerMs / 1000) * (1 + 1.5 * k)
    }

    /// Flicker: dark until its start; then flashes of uneven length and brightness with dark gaps
    /// of uneven length between (some short stutters, some long pauses), then steady on.
    public static func flickerAlpha(_ r: PopInRecipe, index: Int, t: TimeInterval) -> Double {
        let f = flickerTiming(r, index: index)
        let t = t - f.start
        guard t > 0 else { return 0 }
        guard t < f.length else { return 1 }
        let k = min(1, max(0, r.flickerRandomness / 100))
        // Flash, gap, flash, gap, ..., then the letter comes on for good.
        let pieces = f.flashes * 2
        let weights = (0..<pieces).map { piece -> Double in
            let x = letterRandom(index, piece + 1)
            // Flashes 0.25-1.25, gaps 0.15-2.35 (squared, so most are short with the odd long pause).
            let raw = piece % 2 == 0 ? 0.25 + x : 0.15 + 2.2 * x * x
            return 1 + k * (raw - 1)
        }
        let total = weights.reduce(0, +)
        var at = 0.0
        for (piece, w) in weights.enumerated() {
            at += w / total * f.length
            if t < at {
                guard piece % 2 == 0 else { return 0 }
                return 0.3 + 0.7 * letterRandom(index, 100 + piece)
            }
        }
        return 1
    }

    /// Wave: fades in fast and bobs up and down `waveCount` times, dying away.
    public static func wavePose(_ r: PopInRecipe, t: TimeInterval) -> (alpha: Double, dy: Double) {
        guard t > 0 else { return (0, 0) }
        let p = t / max(0.01, r.waveMs / 1000)
        guard p < 1 else { return (1, 0) }
        let dy = r.waveHeight * sin(2 * .pi * max(0.5, r.waveCount) * p) * pow(1 - p, 1.5)
        return (smooth(p / 0.15), dy)
    }

    /// Assemble: starts `assembleDistance` away in the letter's own direction and turned up to
    /// `assembleSpin`, then glides in, easing out, fading in over the first 40 %.
    public static func assemblePose(_ r: PopInRecipe, index: Int, t: TimeInterval)
        -> (alpha: Double, dx: Double, dy: Double, spin: Double) {
        let p = min(1, max(0, t / max(0.01, r.assembleMs / 1000)))
        guard t > 0 else { return (0, 0, 0, 0) }
        guard p < 1 else { return (1, 0, 0, 0) }
        let angle = letterRandom(index, 7) * 2 * .pi
        let reach = r.assembleDistance * (0.6 + 0.4 * letterRandom(index, 8))
        let left = pow(1 - p, 3)
        let spin = r.assembleSpin * (letterRandom(index, 9) * 2 - 1) * left
        return (smooth(p / 0.4), reach * cos(angle) * left, reach * sin(angle) * left, spin)
    }

    /// Glow: appears flaring (full glow after the first 12 %), then cools to none by `glowMs`.
    public static func glowPose(_ r: PopInRecipe, t: TimeInterval) -> (alpha: Double, glow: Double) {
        guard t > 0 else { return (0, 0) }
        let p = t / max(0.01, r.glowMs / 1000)
        guard p < 1 else { return (1, 0) }
        let glow = p < 0.12 ? smooth(p / 0.12) : 1 - smooth((p - 0.12) / 0.88)
        return (smooth(p / 0.1), glow)
    }

    /// Phase: afterimages fade in at their starting size and shrink into the letter by 75 %, fading
    /// as the letter itself comes in (from 30 % to 75 %).
    public static func phasePose(_ r: PopInRecipe, t: TimeInterval) -> (alpha: Double, spread: Double, echoAlpha: Double) {
        guard t > 0 else { return (0, 1, 0) }
        let p = t / max(0.01, r.phaseMs / 1000)
        guard p < 1 else { return (1, 0, 0) }
        let spread = 1 - smooth(p / 0.75)
        let echoAlpha = smooth(p / 0.15) * (1 - smooth((p - 0.4) / 0.45))
        return (smooth((p - 0.3) / 0.45), spread, echoAlpha)
    }

    /// Ripple: fades in over the first 25 % while a wave runs through the letter, its bend dying out.
    /// Each letter's wave starts at its own point, so neighbors don't move in step.
    public static func ripplePose(_ r: PopInRecipe, index: Int, t: TimeInterval)
        -> (alpha: Double, strength: Double, phase: Double) {
        guard t > 0 else { return (0, r.rippleStrength, 0) }
        let p = t / max(0.01, r.rippleMs / 1000)
        guard p < 1 else { return (1, 0, 0) }
        let phase = letterRandom(index, 11) * 2 * .pi + 2 * .pi * 2.5 * p
        return (smooth(p / 0.25), r.rippleStrength * pow(1 - p, 1.5), phase)
    }

    /// Imprint: falls from `imprintFromPercent` to its own size over the first 30 % (speeding up, like
    /// a stamp coming down), squashes on impact, and looks pressed in from impact, easing out over the
    /// last 40 %.
    public static func imprintPose(_ r: PopInRecipe, t: TimeInterval)
        -> (alpha: Double, scaleX: Double, scaleY: Double, inset: Double) {
        guard t > 0 else { return (0, 1, 1, 0) }
        let p = t / max(0.01, r.imprintMs / 1000)
        guard p < 1 else { return (1, 1, 1, 0) }
        let from = max(0.1, r.imprintFromPercent / 100)
        let impact = 0.3
        var scale = 1.0
        if p < impact {
            let f = p / impact
            scale = from + (1 - from) * f * f
        }
        var squash = 0.0
        if p >= impact, p < impact + 0.25 { squash = sin(.pi * (p - impact) / 0.25) }
        let depth = min(1, max(0, r.imprintDepth / 100))
        let inset = p < impact ? 0 : depth * (1 - smooth((p - 0.6) / 0.4))
        return (smooth(p / 0.12), scale * (1 + 0.08 * squash), scale * (1 - 0.12 * squash), inset)
    }

    // MARK: Paw walk

    /// How long a print takes to fade out once it has lingered, and how long after a paw lands its
    /// first letter is stamped, in ms.
    public static let pawFadeMs = 250.0
    public static let pawPressMs = 50.0
    /// A cat's paws: with `PawTrail.fourPaws` no more prints show at once.
    public static let pawCount = 4

    /// Letters each step reveals (at least 1).
    public static func pawLetters(_ r: PopInRecipe) -> Int { max(1, Int(r.pawLettersPerStep.rounded())) }

    /// Steps the walk takes over `characters` letters.
    public static func pawSteps(_ r: PopInRecipe, characters: Int) -> Int {
        let n = pawLetters(r)
        return max(1, (max(1, characters) + n - 1) / n)
    }

    /// Seconds between steps: the step time, quicker if the walk would pass its "at most".
    public static func pawStepSeconds(_ r: PopInRecipe, characters: Int) -> TimeInterval {
        let steps = Double(pawSteps(r, characters: characters))
        return max(0.0001, min(max(10, r.pawStepMs), max(0, r.pawMaxMs) / steps) / 1000)
    }

    /// Seconds after its paw lands that the letter `offset` letters into the step is stamped: the
    /// press, then the step's letters ripple out over `pawSpread` of the step.
    static func pawLetterDelay(_ r: PopInRecipe, offset: Int, step: TimeInterval) -> TimeInterval {
        let spread = min(1, max(0, r.pawSpread / 100)) * step
        return min(pawPressMs / 1000, 0.5 * step) + spread * Double(offset) / Double(pawLetters(r))
    }

    /// Seconds after the pop-in starts that letter `index` (counted from the original text's front)
    /// starts its own effects, when every letter is there from the start: with Paw walk, once its
    /// step's paw has landed (see `PawWalk` for text that streams in); else `index` letters into the
    /// sweep.
    public static func letterStart(_ r: PopInRecipe, index: Int, rate: TimeInterval) -> TimeInterval {
        guard r.pawsOn else { return Double(index) * rate }
        let n = pawLetters(r)
        let step = Double(n) * rate
        return Double(index / n) * step + pawLetterDelay(r, offset: index % n, step: step)
    }

    /// `letterStart` minus the plain sweep's start (0 without Paw walk).
    public static func letterLag(_ r: PopInRecipe, index: Int, rate: TimeInterval) -> TimeInterval {
        letterStart(r, index: index, rate: rate) - Double(index) * rate
    }

    /// One toe-bean print: the letters it stands by (in the current text, clamped to it), whether it
    /// sits above the line, which calico color (0 orange, 1 black, 2 cream), and its look.
    public struct PawPrint: Equatable, Sendable {
        public var first: Int
        public var last: Int
        public var above: Bool
        public var color: Int
        public var alpha: Double
        /// 1 = its size; a print lands from a little larger.
        public var scale: Double
        /// Degrees off pointing right (toes forward), alternating per step.
        public var tilt: Double
    }

    /// A print's look `age` seconds after its paw lands, as step `ordinal` of a walk stepping every
    /// `step` seconds; nil once it has gone.
    static func pawPrint(_ r: PopInRecipe, first: Int, last: Int, ordinal: Int, age: TimeInterval,
                         step: TimeInterval) -> PawPrint? {
        guard age >= 0 else { return nil }
        // The paw settles in over a little of the step, easing out, rather than popping.
        let land = min(0.12, max(0.03, 0.6 * step))
        let settle = smooth(age / land)
        var alpha = settle
        switch r.pawTrail {
        case .fourPaws:
            // Gone just as the fourth step after it lands: never more than four prints at once.
            let lift = Double(pawCount - 1) * step
            guard age < lift + step else { return nil }
            alpha *= 1 - smooth((age - lift) / step)
        case .faded:
            let linger = max(0, r.pawLingerMs) / 1000
            let rest = min(1, max(0, r.pawTrailOpacity / 100))
            alpha *= 1 - (1 - rest) * smooth((age - linger) / (pawFadeMs / 1000))
            guard alpha > 0.001 || age < linger else { return nil }
        }
        let above = ordinal % 2 == 0
        return PawPrint(first: first, last: last, above: above, color: ordinal % 3, alpha: alpha,
                        scale: 1 + 0.15 * (1 - settle), tilt: above ? 12 : -12)
    }

    /// The prints showing `elapsed` seconds into a walk at `rate` seconds a letter, over `characters`
    /// letters that have lost `shift` from the original front, when every letter is there from the
    /// start.
    public static func pawPrints(_ r: PopInRecipe, characters: Int, shift: Int, elapsed: TimeInterval,
                                 rate: TimeInterval) -> [PawPrint] {
        guard r.pawsOn else { return [] }
        var walk = PawWalk(r, characters: characters + max(0, shift))
        walk.advance(to: elapsed, characters: characters + max(0, shift))
        walk.dropFront(max(0, shift))
        return walk.prints(r, at: elapsed)
    }

    /// Seconds after its last step that a walk is done moving: its letters stamped and its prints
    /// gone or faded to the trail.
    static func pawQuiet(_ r: PopInRecipe, step: TimeInterval) -> TimeInterval {
        let letters = pawLetterDelay(r, offset: pawLetters(r) - 1, step: step) + letterTailMs(r, paws: false) / 1000
        let prints = r.pawTrail == .fourPaws
            ? Double(pawCount) * step
            : (max(0, r.pawLingerMs) + pawFadeMs) / 1000
        return max(letters, prints)
    }

    /// The calico prints' colors (orange, black, cream) and the toe beans' pink, as sRGB.
    public static let pawColors: [RGBAColor] = [
        RGBAColor(red: 0.91, green: 0.54, blue: 0.23),
        RGBAColor(red: 0.30, green: 0.27, blue: 0.27),
        RGBAColor(red: 0.95, green: 0.88, blue: 0.75),
    ]
    public static let beanPink = RGBAColor(red: 0.97, green: 0.63, blue: 0.71)

    /// A print's pads in a box `size` wide pointing up, centered on (0, 0): the main pad, then four
    /// toes, each as an ellipse's center and radii.
    public static func pawPads(size: Double) -> [(x: Double, y: Double, rx: Double, ry: Double)] {
        let s = size
        return [(0, -0.17 * s, 0.27 * s, 0.22 * s),
                (-0.34 * s, 0.10 * s, 0.11 * s, 0.14 * s),
                (-0.13 * s, 0.30 * s, 0.11 * s, 0.14 * s),
                (0.13 * s, 0.30 * s, 0.11 * s, 0.14 * s),
                (0.34 * s, 0.10 * s, 0.11 * s, 0.14 * s)]
    }

    /// How long after the sweep reaches a letter its glow starts: once a flickering letter stays lit
    /// (the latest any can), or as a phasing letter starts to show.
    static func glowDelay(_ r: PopInRecipe) -> TimeInterval {
        if r.flickerOn { return flickerLatestSettle(r) }
        if r.phaseOn { return 0.3 * max(0, r.phaseMs) / 1000 }
        return 0
    }

    /// Seconds after the sweep reaches a letter that it "lands" (sheds its particles): once Hang has
    /// dropped it, Assemble brought it in or Flicker left it on; at its glow's peak; else at once.
    public static func landDelay(_ recipe: PopInRecipe) -> TimeInterval {
        var ms = 0.0
        if recipe.hangOn { ms = max(ms, 0.6 * recipe.hangMs) }
        if recipe.assembleOn { ms = max(ms, 0.7 * recipe.assembleMs) }
        if recipe.phaseOn { ms = max(ms, 0.45 * recipe.phaseMs) }
        if recipe.rippleOn { ms = max(ms, 0.2 * recipe.rippleMs) }
        if recipe.imprintOn { ms = max(ms, 0.3 * recipe.imprintMs) }
        if recipe.flickerOn { ms = max(ms, flickerLatestSettle(recipe) * 1000) }
        if recipe.glowOn { ms = max(ms, 0.12 * recipe.glowMs) }
        return max(0, ms) / 1000
    }

    /// `landDelay` for one letter: a flickering letter lands when it stays lit.
    public static func letterLandDelay(_ recipe: PopInRecipe, index: Int) -> TimeInterval {
        guard recipe.flickerOn else { return landDelay(recipe) }
        var r = recipe
        r.flickerOn = false
        return max(landDelay(r), flickerSettle(recipe, index: index))
    }

    /// How long after the sweep reaches a letter its color fade starts: once a flickering letter
    /// stays lit, else at once.
    public static func letterFadeDelay(_ recipe: PopInRecipe, index: Int) -> TimeInterval {
        recipe.flickerOn ? flickerSettle(recipe, index: index) : 0
    }

    /// Particles per letter: `density` on average, spread evenly (0.5 = every other letter, starting
    /// with the first); spaces shed none.
    public static func particleCounts(_ text: String, density: Double) -> [Int] {
        var carry = 0.5
        return text.map { ch in
            guard !ch.isWhitespace else { return 0 }
            carry += max(0, density)
            let n = Int(carry.rounded(.down))
            carry -= Double(n)
            return n
        }
    }

    /// A particle's flight as `steps + 1` evenly timed points from `start` (AppKit coords, up =
    /// positive). `direction` and `gravityDirection` are in degrees, 0 = down, 90 = right, 180 = up;
    /// flutter sways it across the pull, starting at `phase` (radians).
    public static func particlePath(start: CGPoint, speed: Double, direction: Double, gravity: Double,
                                 gravityDirection: Double = 0, flutter: Double, phase: Double,
                                 life: TimeInterval, steps: Int = 16) -> [CGPoint] {
        let rad = direction * .pi / 180
        let vx = speed * sin(rad), vy = -speed * cos(rad)
        let g = gravityDirection * .pi / 180
        let gx = gravity * sin(g), gy = -gravity * cos(g)
        // Sway runs across the pull: sideways for falling, up and down for a sideways wind.
        let sx = cos(g), sy = sin(g)
        return (0...max(1, steps)).map { i in
            let t = life * Double(i) / Double(max(1, steps))
            let sway: Double = flutter * (sin(2 * .pi * t / 0.9 + phase) - sin(phase))
            let x: Double = start.x + vx * t + 0.5 * gx * t * t + sway * sx
            let y: Double = start.y + vy * t + 0.5 * gy * t * t + sway * sy
            return CGPoint(x: x, y: y)
        }
    }

    /// "While shown" or how long particles keep trickling after the pop-in, in seconds (0 = none).
    public static func particleTrickleSeconds(_ recipe: PopInRecipe) -> TimeInterval? {
        guard recipe.particlesOn, recipe.particleEmitMs > 0, recipe.particleTrickle > 0 else { return 0 }
        return recipe.particleEmitMs >= PopInRecipe.particleEmitWhileShown ? nil : recipe.particleEmitMs / 1000
    }

    /// How long one letter takes to fade from Color fade's color, in ms (0 = Color fade off).
    public static func letterFadeMs(_ recipe: PopInRecipe) -> Double {
        recipe.colorFadeOn ? max(0, recipe.colorFadeMs) : 0
    }

    /// Color fade's whole run: the sweep plus the last letter's fade, in seconds.
    public static func colorFadeDuration(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        sweepRate(recipe, characters: characters) * Double(max(1, characters)) + letterFadeMs(recipe) / 1000
    }

    /// Where the sweep is, in letters, when per-letter drawing can stop: every letter in, faded
    /// and settled.
    public static func sweepEnd(_ recipe: PopInRecipe, characters: Int) -> Double {
        let tail = letterTailMs(recipe) / 1000
        return Double(characters) + tail / max(0.0001, sweepRate(recipe, characters: characters))
    }

    /// Seconds between letters locking in: the per-letter time, faster if the cap would be passed.
    public static func decodeRate(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        min(max(1, recipe.decodeMsPerLetter), recipe.decodeMaxMs / Double(max(1, characters))) / 1000
    }

    /// The whole scramble, until the last letter locks in, in seconds.
    public static func decodeDuration(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        decodeRate(recipe, characters: characters) * Double(max(1, characters))
    }

    /// One frame of a decode: each letter before `locked` is real, the rest are picked from `pool`
    /// (spaces stay spaces, so word shapes show). `tick` changes the picks; the same inputs always
    /// give the same frame.
    public static func decodeFrame(_ text: String, locked: Double, tick: Int, pool: [Character]) -> [Character] {
        guard !pool.isEmpty else { return Array(text) }
        return text.enumerated().map { i, ch in
            if Double(i) < locked || ch.isWhitespace { return ch }
            // A small integer hash of (position, tick): cheap, stable, well spread.
            var h = UInt64(i &* 73_856_093) ^ UInt64(truncatingIfNeeded: tick &* 19_349_663)
            h = (h ^ (h >> 13)) &* 0x5bd1e995
            h ^= h >> 15
            return pool[Int(h % UInt64(pool.count))]
        }
    }

    /// How much of Color fade's color a letter shows: 1 until the sweep reaches it (scrambled, with
    /// Scramble on), then fading smoothly to 0 over `fadeMs` (eased, so the trail has no hard edge).
    /// `delay` holds the color for that many more seconds after the sweep reaches it.
    public static func decodeTint(index: Int, locked: Double, rate: TimeInterval, fadeMs: Double,
                                  delay: TimeInterval = 0) -> Double {
        if Double(index) >= locked { return 1 }
        // Letter `index` locked when `locked` passed index + 1... measured from when it turned real.
        let sinceLock = (locked - Double(index)) * rate - delay
        if sinceLock < 0 { return 1 }
        guard fadeMs > 0 else { return 0 }
        let p = min(1, max(0, sinceLock / (fadeMs / 1000)))
        return 1 - p * p * (3 - 2 * p)
    }

    /// How many characters the ghost lost at its front between two redraws: typed through (+n),
    /// grown at the end (0), backspaced into (-n). Nil when `next` doesn't continue `previous`.
    public static func typewriterShift(previous: String, next: String) -> Int? {
        if next.hasPrefix(previous) { return 0 }
        if previous.hasSuffix(next) { return previous.count - next.count }
        if next.hasSuffix(previous) { return -(next.count - previous.count) }
        return nil
    }

    /// Where a finished typewriter or per-letter effect picks up when the suggestion grows at its end
    /// (the next streamed words arrived after the effect had caught up): the count already shown.
    /// Nil when nothing new was added at the end.
    public static func revealResume(previousShown: String, nextShown: String) -> Int? {
        guard nextShown.count > previousShown.count, nextShown.hasPrefix(previousShown) else { return nil }
        return previousShown.count
    }

    /// Characters of the current text revealed `elapsed` seconds into a typewriter reveal running at
    /// `rate` seconds per character, after `shift` characters left its front.
    public static func typewriterRevealed(elapsed: TimeInterval, rate: TimeInterval, shift: Int) -> Double {
        max(0, elapsed / max(0.0001, rate) - Double(shift))
    }

    /// Rise (or drop) with an overshoot: vertical offsets, up = positive, and their key times.
    /// A positive distance starts below and rises; the bob overshoots in the direction of travel.
    public static func riseKeyframes(distance: Double, bob: Double) -> (values: [Double], times: [Double]) {
        let overshoot = (distance >= 0 ? 1.0 : -1.0) * max(0, bob)
        guard overshoot != 0 else { return ([-distance, 0], [0, 1]) }
        return ([-distance, overshoot, -0.3 * overshoot, 0], [0, 0.55, 0.82, 1])
    }

    /// Wobbles that shrink to nothing: vertical offsets, up = positive, evenly spaced in time.
    /// `count` full wobbles (two half-swings each, rounded to a half).
    public static func wiggleKeyframes(height: Double, count: Double) -> (values: [Double], times: [Double]) {
        let swings = max(1, Int((count * 2).rounded()))
        var values = [0.0]
        for i in 1...swings {
            let decay = 1 - Double(i - 1) / Double(swings)
            values.append(height * (i % 2 == 1 ? 1 : -1) * decay)
        }
        values.append(0)
        let times = values.indices.map { Double($0) / Double(values.count - 1) }
        return (values, times)
    }

    /// Room the panel needs around the text so nothing is clipped mid-animation, in points.
    /// `unit` is the text-size scale applied to distances; `size` is the text's own box.
    public static func margin(_ recipe: PopInRecipe, unit: Double, size: CGSize) -> CGFloat {
        var m = 8.0
        if recipe.slideOn { m = max(m, abs(recipe.slideDistance) * unit + 2) }
        if recipe.riseOn { m = max(m, (abs(recipe.riseDistance) + abs(recipe.bobDistance)) * unit + 2) }
        if recipe.wiggleOn { m = max(m, abs(recipe.wiggleHeight) * unit + 2) }
        if recipe.blurOn { m = max(m, recipe.blurRadius * unit * 2 + 2) }
        if recipe.hangOn {
            let tilt = Double(size.height) * sin(min(90, abs(recipe.hangSwing)) * .pi / 180)
            m = max(m, (abs(recipe.hangDrop) + abs(recipe.hangBob)) * unit + tilt + 2)
        }
        if recipe.particlesOn { m = max(m, max(0, recipe.particleRoom) * unit + 2) }
        if recipe.waveOn { m = max(m, abs(recipe.waveHeight) * unit + 2) }
        if recipe.assembleOn { m = max(m, abs(recipe.assembleDistance) * unit + Double(size.height) * 0.5 + 2) }
        if recipe.glowOn { m = max(m, max(0, recipe.glowRadius) * unit * 1.5 + 2) }
        if recipe.phaseOn {
            let grow = Double(size.height) * 0.5 * max(0, recipe.phaseScale / 100 - 1)
            m = max(m, grow + max(0, recipe.phaseBlur) * unit * 2 + 2)
        }
        if recipe.rippleOn { m = max(m, abs(recipe.rippleStrength) * unit + 2) }
        if recipe.pawsOn { m = max(m, max(0, recipe.pawSize) * unit * 1.35 + 3) }
        if recipe.imprintOn {
            // Letters grow about their baseline, so up by their height's extra.
            m = max(m, Double(size.height) * max(0, recipe.imprintFromPercent / 100 - 1) + 2)
        }
        if recipe.growOn, recipe.growFromPercent > 100 {
            let extra = recipe.growFromPercent / 100 - 1
            m = max(m, Double(max(size.width, size.height)) * extra + 2)
        }
        return CGFloat(m.rounded(.up))
    }

    /// The default grey (also used when the host reports no text color).
    public static let grey = RGBAColor(red: 0.55, green: 0.55, blue: 0.55)

    /// The ghost's color. The per-app "Always grey" wins over the choice. Grey is already light, so it
    /// is solid from the default strength (0.5) up and fades below it; every other color is drawn at
    /// `opacity` (the host's own alpha, at least 0.2, scales "match text"). Follow effect uses
    /// `effect` (the style's final color), or matches the text when the style has none.
    public static func color(choice: SuggestionColorChoice, opacity: Double, textColor: RGBAColor?,
                             greyForced: Bool, accent: RGBAColor, custom: RGBAColor,
                             effect: RGBAColor? = nil) -> RGBAColor {
        let strength = CGFloat(opacity)
        func greyColor() -> RGBAColor {
            var g = grey
            g.alpha = min(1, strength * 2)
            return g
        }
        if greyForced { return greyColor() }
        var choice = choice
        if choice == .followEffect {
            if var c = effect {
                c.alpha = strength
                return c
            }
            choice = .matchText
        }
        switch choice {
        case .grey:
            return greyColor()
        case .matchText, .followEffect:
            guard var c = textColor else { return greyColor() }
            c.alpha = max(0.2, min(1, c.alpha)) * strength
            return c
        case .accent:
            var c = accent
            c.alpha = strength
            return c
        case .custom:
            var c = custom
            c.alpha = strength
            return c
        }
    }
}
