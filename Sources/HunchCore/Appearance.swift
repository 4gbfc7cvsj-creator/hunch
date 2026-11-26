import Foundation

/// How a new suggestion appears (Settings → Appearance). Typing through a suggestion never replays it.
public enum PopInAnimation: String, Codable, Sendable, CaseIterable {
    /// Appears at once (the original behavior).
    case none
    case fade
    /// Fades in while sliding a few points out of the caret.
    case fadeSlide
    /// Characters appear left to right.
    case typewriter
    /// Spooky: fades in while rising from just below the line, bobs once, settles.
    case floatUp
    /// Spooky: fades in with a few small up/down wobbles that die out.
    case wiggle
    /// Spooky: sharpens from a blur.
    case materialize
    /// Matrix: scrambled green characters lock into the real text left to right (Scramble + Color fade).
    case decode
    /// Wisteria: letters hang down and swing into place in lilac, shedding petals.
    case wisteria
    /// Autumn: letters hang down and swing into place in orange, shedding red-to-yellow leaves.
    case autumn
    /// Winter: letters hang down and swing into place in icy cyan, shedding snowflakes.
    case winter
    /// Neon: letters flicker on like a sign warming up, in hot pink, throwing a few sparks.
    case neon
    /// Ocean: a ripple runs through the letters in sea blue while bubbles float up.
    case ocean
    /// Stardust: letters fly in from scattered spots and lock into place in gold, among sparkles.
    case stardust
    /// Ember: each letter flares with a warm glow that cools, while embers drift up on the wind.
    case ember
    /// Spooky (stored as `ghost`, its old name, so saved settings load): each letter appears through
    /// a liquid ripple that calms, fading from pale green to lavender, while small wisps and mist drift up.
    case spooky = "ghost"
    /// Paws: calico toe-bean prints walk along the line, and the letters under each step are
    /// stamped into the page.
    case paws
    /// Built from effects in Settings → Appearance (`AppearanceSettings.customRecipe`).
    case custom
}

/// What the Scramble effect scrambles with.
/// What Paw walk's prints do once the cat has stepped on.
public enum PawTrail: String, Codable, Sendable, CaseIterable {
    /// Only the cat's four paws show: each print lifts as the fourth step after it lands.
    case fourPaws
    /// Prints stay behind, faded, for as long as the suggestion shows.
    case faded
}

public enum DecodeCharacters: String, Codable, Sendable, CaseIterable {
    case lettersAndNumbers, symbols, katakana

    public var pool: [Character] {
        switch self {
        case .lettersAndNumbers: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        case .symbols: Array("!@#$%^&*<>/\\|{}[]=+-~?;:")
        case .katakana: Array("\u{FF71}\u{FF72}\u{FF73}\u{FF74}\u{FF75}\u{FF76}\u{FF77}\u{FF78}\u{FF79}\u{FF7A}"
                              + "\u{FF7B}\u{FF7C}\u{FF7D}\u{FF7E}\u{FF7F}\u{FF80}\u{FF81}\u{FF82}\u{FF83}\u{FF84}"
                              + "\u{FF85}\u{FF86}\u{FF87}\u{FF88}\u{FF89}\u{FF8A}\u{FF8B}\u{FF8C}\u{FF8D}\u{FF8E}"
                              + "\u{FF8F}\u{FF90}\u{FF91}\u{FF92}\u{FF93}\u{FF94}\u{FF95}\u{FF96}\u{FF97}\u{FF98}"
                              + "\u{FF99}\u{FF9A}\u{FF9B}\u{FF9C}\u{FF9D}0123456789")
        }
    }
}

/// The color the Color fade effect starts each letter in, before fading to the suggestion's color.
public enum ColorFadeColor: String, Codable, Sendable, CaseIterable {
    /// The suggestion's own color at full strength.
    case bright
    /// Terminal green.
    case green
    /// `PopInRecipe.colorFadeCustom`.
    case custom
}

/// A shape the Particles effect can shed.
public enum ParticleShape: String, Codable, Sendable, CaseIterable {
    case petal, leaf, blossom, dot, sparkle, star, square, heart, snowflake, bubble
    /// A small ghost: round head, wavy hem, two eyes.
    case wisp
    /// A soft puff that swells as it fades.
    case mist
}

/// A pop-in as a set of effects that all start together, each with its own length. Every style is
/// one of these; distances are in points at 13 pt text and scale with the text size.
public struct PopInRecipe: Codable, Sendable, Equatable {
    public var fadeOn = false
    public var fadeMs: Double = 120

    public var slideOn = false
    /// Where the text starts, in points: negative = left of its place, positive = right.
    public var slideDistance: Double = -6
    public var slideMs: Double = 160

    public var riseOn = false
    /// Where the text starts, in points: positive = below its place (rises), negative = above (drops).
    public var riseDistance: Double = 4
    /// How far it overshoots its place before settling (0 = no bob).
    public var bobDistance: Double = 1
    public var riseMs: Double = 380

    public var wiggleOn = false
    /// Height of the first wobble, in points; later ones shrink to nothing.
    public var wiggleHeight: Double = 1.6
    public var wiggleCount: Double = 2.5
    public var wiggleMs: Double = 550

    public var blurOn = false
    public var blurRadius: Double = 3.5
    public var blurMs: Double = 300

    public var growOn = false
    /// Starting size in percent of the final size: under 100 grows, over 100 shrinks into place.
    public var growFromPercent: Double = 60
    public var growMs: Double = 200

    public var typewriterOn = false
    public var typewriterMsPerCharacter: Double = 22
    /// The whole reveal never takes longer than this.
    public var typewriterMaxMs: Double = 450

    /// Scramble (stored as `decode…` so older saves load): random characters lock into the real
    /// text left to right.
    public var decodeOn = false
    /// Time between one letter locking in and the next.
    public var decodeMsPerLetter: Double = 30
    /// The whole decode never takes longer than this.
    public var decodeMaxMs: Double = 500
    /// How often a scrambled letter changes.
    public var decodeScrambleMs: Double = 50
    public var decodeCharacters: DecodeCharacters = .lettersAndNumbers

    /// Color fade: each letter starts in a color and fades to the suggestion's, left to right. With
    /// Scramble on, it follows the scramble instead (a letter fades once it locks in), and its own
    /// sweep speed is unused.
    public var colorFadeOn = false
    public var colorFadeColor: ColorFadeColor = .green
    public var colorFadeCustom = StoredColor(red: 0.2, green: 0.95, blue: 0.4)
    /// Time between one letter starting to fade and the next.
    public var colorFadeMsPerLetter: Double = 30
    /// The whole sweep never takes longer than this (the letters' own fades come on top).
    public var colorFadeMaxMs: Double = 500
    /// How long one letter takes to fade to the suggestion's color.
    public var colorFadeMs: Double = 300

    /// Hang: letters drop in left to right, swinging from their tops before they settle.
    public var hangOn = false
    /// Where each letter starts, in points above its place (negative = below).
    public var hangDrop: Double = 5
    /// How far a letter dips past its place before settling.
    public var hangBob: Double = 1
    /// The first swing's tilt in degrees (0 = no tilt); later swings die out.
    public var hangSwing: Double = 10
    /// Time between one letter starting and the next.
    public var hangMsPerLetter: Double = 40
    /// The whole sweep never takes longer than this.
    public var hangMaxMs: Double = 700
    /// How long one letter takes to drop, swing and settle.
    public var hangMs: Double = 800

    /// Particles: small shapes shed from each letter as it lands (or appears).
    public var particlesOn = false
    public var particleShapes: [ParticleShape] = [.petal, .blossom]
    /// Each particle gets a random shade between these two.
    public var particleColorA = StoredColor(red: 0.88, green: 0.80, blue: 0.98)
    public var particleColorB = StoredColor(red: 0.52, green: 0.33, blue: 0.80)
    /// Particles per letter on average (fractions spread out: 0.5 = every other letter).
    public var particleDensity: Double = 0.5
    /// Particle size in points, and how much sizes vary (percent either way).
    public var particleSize: Double = 4
    public var particleSizeVariation: Double = 40
    /// Starting speed in points per second (varies ±30 %).
    public var particleSpeed: Double = 12
    /// How hard gravity pulls, in points per second per second.
    public var particleGravity: Double = 25
    /// Which way gravity pulls, in degrees: 0 = down, 90 = right, -90 = left, 180 = up.
    public var particleGravityDirection: Double = 0
    /// Starting direction in degrees: 0 = down, 90 = right, -90 = left, 180 = up.
    public var particleDirection: Double = 0
    /// How widely directions spread around it, in degrees.
    public var particleSpread: Double = 50
    /// Side-to-side drift while falling, in points.
    public var particleFlutter: Double = 3
    /// Turning speed in degrees per second (each particle picks a direction).
    public var particleSpin: Double = 120
    /// How long a particle lives, and how long its fade-out at the end takes.
    public var particleLifeMs: Double = 1400
    public var particleFadeMs: Double = 500
    /// How long particles keep trickling from the whole line after the pop-in, in ms; 0 = pop-in only,
    /// `particleEmitWhileShown` or more = for as long as the suggestion shows.
    public var particleEmitMs: Double = 0
    /// Particles per second while trickling.
    public var particleTrickle: Double = 2
    /// How far particles may travel from the text, in points; they fade out at that edge.
    public var particleRoom: Double = 30

    /// Flicker: each letter stutters on and off a few times before it stays lit, left to right.
    public var flickerOn = false
    /// Flashes before a letter stays on.
    public var flickerCount: Double = 3
    /// How long one letter flickers.
    public var flickerMs: Double = 450
    public var flickerMsPerLetter: Double = 35
    public var flickerMaxMs: Double = 600
    /// How irregular it is, in percent: each letter's start, length, flash count and flash/gap
    /// lengths vary this much (0 = every letter flickers the same way, in step).
    public var flickerRandomness: Double = 100

    /// Wave: a ripple runs through the letters left to right, each bobbing after the one before.
    public var waveOn = false
    /// Height of a letter's first bob, in points; later ones die out.
    public var waveHeight: Double = 3
    /// Bobs per letter.
    public var waveCount: Double = 1.5
    /// How long one letter bobs.
    public var waveMs: Double = 700
    public var waveMsPerLetter: Double = 30
    public var waveMaxMs: Double = 600

    /// Assemble: each letter flies in from a scattered spot, spinning, and locks into place.
    public var assembleOn = false
    /// How far away letters start, in points (each picks its own direction).
    public var assembleDistance: Double = 14
    /// How far a letter turns on the way in, in degrees (either way).
    public var assembleSpin: Double = 120
    /// How long one letter takes to arrive.
    public var assembleMs: Double = 550
    public var assembleMsPerLetter: Double = 25
    public var assembleMaxMs: Double = 500

    /// Glow: each letter flares with a halo as it appears, then cools to normal.
    public var glowOn = false
    public var glowColor = StoredColor(red: 1, green: 0.7, blue: 0.28)
    /// The halo's blur radius, in points.
    public var glowRadius: Double = 6
    /// How long one letter's glow takes to die down.
    public var glowMs: Double = 700
    public var glowMsPerLetter: Double = 30
    public var glowMaxMs: Double = 600

    /// Phase: each letter surfaces from depth, as faint afterimages around it that shrink into it
    /// before it turns solid.
    public var phaseOn = false
    /// How many afterimages.
    public var phaseEchoes: Double = 3
    /// The outermost afterimage's starting size, in percent of the letter.
    public var phaseScale: Double = 180
    /// The outermost afterimage's starting blur, in points.
    public var phaseBlur: Double = 3
    /// How long one letter takes to surface.
    public var phaseMs: Double = 750
    public var phaseMsPerLetter: Double = 35
    public var phaseMaxMs: Double = 600

    /// Ripple: each letter appears warped by a wave running through it, which calms to straight.
    public var rippleOn = false
    /// How far the warp bends a letter at first, in points.
    public var rippleStrength: Double = 2
    /// Waves across a letter's height.
    public var rippleWaves: Double = 1.5
    /// How long one letter takes to calm.
    public var rippleMs: Double = 800
    public var rippleMsPerLetter: Double = 30
    public var rippleMaxMs: Double = 600

    /// Paw walk: toe-bean prints step along the line, alternating above and below it, in calico
    /// orange, black and cream; the letters under a step appear once the paw lands. Leads the sweep.
    public var pawsOn = false
    /// Letters each step reveals.
    public var pawLettersPerStep: Double = 4
    /// Time between one step and the next.
    public var pawStepMs: Double = 100
    /// The whole walk never takes longer than this (steps quicken to fit).
    public var pawMaxMs: Double = 600
    /// A print's size, in points.
    public var pawSize: Double = 13
    /// How long a print stays before it fades out (to the trail, with a faded trail).
    public var pawLingerMs: Double = 450
    /// Four live paws, or a faded trail.
    public var pawTrail: PawTrail = .fourPaws
    /// A faded trail's strength, in percent of a fresh print.
    public var pawTrailOpacity: Double = 25
    /// How much of a step a paw's letters spread their stamping over, in percent: 0 stamps them all
    /// at once, 100 ripples them out until the next step lands.
    public var pawSpread: Double = 50

    /// Imprint: each letter is stamped down from larger with a squash, looking pressed into the page
    /// at first, then settles.
    public var imprintOn = false
    /// Starting size in percent of the letter's.
    public var imprintFromPercent: Double = 120
    /// How deep the pressed-in look is at first, in percent.
    public var imprintDepth: Double = 70
    /// How long one letter takes to stamp down and settle.
    public var imprintMs: Double = 450
    public var imprintMsPerLetter: Double = 30
    public var imprintMaxMs: Double = 600

    /// Final color: the color the suggestion settles in when Settings → Appearance → Color is
    /// "Follow effect" (drawn at the chosen strength). Off = Match text.
    public var finalColorOn = false
    public var finalColor = StoredColor(red: 0.55, green: 0.35, blue: 0.85)

    /// `particleEmitMs` from here up means "while shown".
    public static let particleEmitWhileShown: Double = 6000

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case fadeOn, fadeMs, slideOn, slideDistance, slideMs, riseOn, riseDistance, bobDistance, riseMs,
             wiggleOn, wiggleHeight, wiggleCount, wiggleMs, blurOn, blurRadius, blurMs, growOn,
             growFromPercent, growMs, typewriterOn, typewriterMsPerCharacter, typewriterMaxMs,
             decodeOn, decodeMsPerLetter, decodeMaxMs, decodeScrambleMs, decodeCharacters,
             colorFadeOn, colorFadeColor, colorFadeCustom, colorFadeMsPerLetter, colorFadeMaxMs, colorFadeMs,
             hangOn, hangDrop, hangBob, hangSwing, hangMsPerLetter, hangMaxMs, hangMs,
             particlesOn, particleShapes, particleColorA, particleColorB, particleDensity, particleSize, particleSizeVariation,
             particleSpeed, particleGravity, particleGravityDirection, particleDirection, particleSpread, particleFlutter, particleSpin, particleLifeMs,
             particleFadeMs, particleEmitMs, particleTrickle, particleRoom,
             flickerOn, flickerCount, flickerMs, flickerMsPerLetter, flickerMaxMs, flickerRandomness,
             waveOn, waveHeight, waveCount, waveMs, waveMsPerLetter, waveMaxMs,
             assembleOn, assembleDistance, assembleSpin, assembleMs, assembleMsPerLetter, assembleMaxMs,
             glowOn, glowColor, glowRadius, glowMs, glowMsPerLetter, glowMaxMs,
             phaseOn, phaseEchoes, phaseScale, phaseBlur, phaseMs, phaseMsPerLetter, phaseMaxMs,
             rippleOn, rippleStrength, rippleWaves, rippleMs, rippleMsPerLetter, rippleMaxMs,
             pawsOn, pawLettersPerStep, pawStepMs, pawMaxMs, pawSize, pawLingerMs, pawTrail, pawTrailOpacity, pawSpread,
             imprintOn, imprintFromPercent, imprintDepth, imprintMs, imprintMsPerLetter, imprintMaxMs,
             finalColorOn, finalColor
        // Older builds: Decode's own color, now the Color fade effect.
        case decodeFlash, decodeFlashMs
    }

    /// Missing keys keep their defaults, so recipes saved by an older build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: AnyKey.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            if let value = try? c.decodeIfPresent(T.self, forKey: key) { return value }
            // Particles were called petals in earlier builds ("petalsOn", "petalSize", ...).
            let old = key.stringValue.replacingOccurrences(of: "particles", with: "petals")
                .replacingOccurrences(of: "particle", with: "petal")
            if old != key.stringValue, let value = try? legacy.decodeIfPresent(T.self, forKey: AnyKey(old)) {
                return value
            }
            return fallback
        }
        let d = PopInRecipe()
        fadeOn = v(.fadeOn, d.fadeOn); fadeMs = v(.fadeMs, d.fadeMs)
        slideOn = v(.slideOn, d.slideOn); slideDistance = v(.slideDistance, d.slideDistance); slideMs = v(.slideMs, d.slideMs)
        riseOn = v(.riseOn, d.riseOn); riseDistance = v(.riseDistance, d.riseDistance)
        bobDistance = v(.bobDistance, d.bobDistance); riseMs = v(.riseMs, d.riseMs)
        wiggleOn = v(.wiggleOn, d.wiggleOn); wiggleHeight = v(.wiggleHeight, d.wiggleHeight)
        wiggleCount = v(.wiggleCount, d.wiggleCount); wiggleMs = v(.wiggleMs, d.wiggleMs)
        blurOn = v(.blurOn, d.blurOn); blurRadius = v(.blurRadius, d.blurRadius); blurMs = v(.blurMs, d.blurMs)
        growOn = v(.growOn, d.growOn); growFromPercent = v(.growFromPercent, d.growFromPercent); growMs = v(.growMs, d.growMs)
        typewriterOn = v(.typewriterOn, d.typewriterOn)
        typewriterMsPerCharacter = v(.typewriterMsPerCharacter, d.typewriterMsPerCharacter)
        typewriterMaxMs = v(.typewriterMaxMs, d.typewriterMaxMs)
        decodeOn = v(.decodeOn, d.decodeOn); decodeMsPerLetter = v(.decodeMsPerLetter, d.decodeMsPerLetter)
        decodeMaxMs = v(.decodeMaxMs, d.decodeMaxMs); decodeScrambleMs = v(.decodeScrambleMs, d.decodeScrambleMs)
        decodeCharacters = v(.decodeCharacters, d.decodeCharacters)
        colorFadeColor = v(.colorFadeColor, d.colorFadeColor); colorFadeCustom = v(.colorFadeCustom, d.colorFadeCustom)
        colorFadeMsPerLetter = v(.colorFadeMsPerLetter, d.colorFadeMsPerLetter)
        colorFadeMaxMs = v(.colorFadeMaxMs, d.colorFadeMaxMs); colorFadeMs = v(.colorFadeMs, d.colorFadeMs)
        hangOn = v(.hangOn, d.hangOn); hangDrop = v(.hangDrop, d.hangDrop); hangBob = v(.hangBob, d.hangBob)
        hangSwing = v(.hangSwing, d.hangSwing); hangMsPerLetter = v(.hangMsPerLetter, d.hangMsPerLetter)
        hangMaxMs = v(.hangMaxMs, d.hangMaxMs); hangMs = v(.hangMs, d.hangMs)
        particlesOn = v(.particlesOn, d.particlesOn); particleShapes = v(.particleShapes, d.particleShapes)
        particleColorA = v(.particleColorA, d.particleColorA); particleColorB = v(.particleColorB, d.particleColorB)
        particleDensity = v(.particleDensity, d.particleDensity); particleSize = v(.particleSize, d.particleSize)
        particleSizeVariation = v(.particleSizeVariation, d.particleSizeVariation); particleSpeed = v(.particleSpeed, d.particleSpeed)
        particleGravity = v(.particleGravity, d.particleGravity); particleDirection = v(.particleDirection, d.particleDirection)
        particleSpread = v(.particleSpread, d.particleSpread); particleFlutter = v(.particleFlutter, d.particleFlutter)
        particleSpin = v(.particleSpin, d.particleSpin); particleLifeMs = v(.particleLifeMs, d.particleLifeMs)
        particleFadeMs = v(.particleFadeMs, d.particleFadeMs); particleEmitMs = v(.particleEmitMs, d.particleEmitMs)
        particleTrickle = v(.particleTrickle, d.particleTrickle); particleRoom = v(.particleRoom, d.particleRoom)
        if c.contains(.particleGravityDirection) {
            particleGravityDirection = v(.particleGravityDirection, d.particleGravityDirection)
        } else if particleGravity < 0 {
            // Saved when gravity was one signed slider (negative = floats up).
            particleGravity = -particleGravity
            particleGravityDirection = 180
        }
        flickerOn = v(.flickerOn, d.flickerOn); flickerCount = v(.flickerCount, d.flickerCount)
        flickerMs = v(.flickerMs, d.flickerMs); flickerMsPerLetter = v(.flickerMsPerLetter, d.flickerMsPerLetter)
        flickerMaxMs = v(.flickerMaxMs, d.flickerMaxMs); flickerRandomness = v(.flickerRandomness, d.flickerRandomness)
        waveOn = v(.waveOn, d.waveOn); waveHeight = v(.waveHeight, d.waveHeight); waveCount = v(.waveCount, d.waveCount)
        waveMs = v(.waveMs, d.waveMs); waveMsPerLetter = v(.waveMsPerLetter, d.waveMsPerLetter)
        waveMaxMs = v(.waveMaxMs, d.waveMaxMs)
        assembleOn = v(.assembleOn, d.assembleOn); assembleDistance = v(.assembleDistance, d.assembleDistance)
        assembleSpin = v(.assembleSpin, d.assembleSpin); assembleMs = v(.assembleMs, d.assembleMs)
        assembleMsPerLetter = v(.assembleMsPerLetter, d.assembleMsPerLetter); assembleMaxMs = v(.assembleMaxMs, d.assembleMaxMs)
        glowOn = v(.glowOn, d.glowOn); glowColor = v(.glowColor, d.glowColor); glowRadius = v(.glowRadius, d.glowRadius)
        glowMs = v(.glowMs, d.glowMs); glowMsPerLetter = v(.glowMsPerLetter, d.glowMsPerLetter)
        glowMaxMs = v(.glowMaxMs, d.glowMaxMs)
        phaseOn = v(.phaseOn, d.phaseOn); phaseEchoes = v(.phaseEchoes, d.phaseEchoes)
        phaseScale = v(.phaseScale, d.phaseScale); phaseBlur = v(.phaseBlur, d.phaseBlur)
        phaseMs = v(.phaseMs, d.phaseMs); phaseMsPerLetter = v(.phaseMsPerLetter, d.phaseMsPerLetter)
        phaseMaxMs = v(.phaseMaxMs, d.phaseMaxMs)
        rippleOn = v(.rippleOn, d.rippleOn); rippleStrength = v(.rippleStrength, d.rippleStrength)
        rippleWaves = v(.rippleWaves, d.rippleWaves); rippleMs = v(.rippleMs, d.rippleMs)
        rippleMsPerLetter = v(.rippleMsPerLetter, d.rippleMsPerLetter); rippleMaxMs = v(.rippleMaxMs, d.rippleMaxMs)
        pawsOn = v(.pawsOn, d.pawsOn); pawLettersPerStep = v(.pawLettersPerStep, d.pawLettersPerStep)
        pawStepMs = v(.pawStepMs, d.pawStepMs); pawMaxMs = v(.pawMaxMs, d.pawMaxMs)
        pawSize = v(.pawSize, d.pawSize); pawLingerMs = v(.pawLingerMs, d.pawLingerMs)
        pawTrail = v(.pawTrail, d.pawTrail); pawTrailOpacity = v(.pawTrailOpacity, d.pawTrailOpacity)
        pawSpread = v(.pawSpread, d.pawSpread)
        imprintOn = v(.imprintOn, d.imprintOn); imprintFromPercent = v(.imprintFromPercent, d.imprintFromPercent)
        imprintDepth = v(.imprintDepth, d.imprintDepth); imprintMs = v(.imprintMs, d.imprintMs)
        imprintMsPerLetter = v(.imprintMsPerLetter, d.imprintMsPerLetter); imprintMaxMs = v(.imprintMaxMs, d.imprintMaxMs)
        finalColorOn = v(.finalColorOn, d.finalColorOn); finalColor = v(.finalColor, d.finalColor)
        if c.contains(.colorFadeOn) {
            colorFadeOn = v(.colorFadeOn, d.colorFadeOn)
        } else if decodeOn {
            // Saved before the split: Decode's color ("off", "bright", or "green" by default)
            // becomes Color fade, so the look stays the same.
            let flash: String = v(.decodeFlash, "green")
            if let color = ColorFadeColor(rawValue: flash) {
                colorFadeOn = true
                colorFadeColor = color
                colorFadeMs = v(.decodeFlashMs, d.colorFadeMs)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fadeOn, forKey: .fadeOn); try c.encode(fadeMs, forKey: .fadeMs)
        try c.encode(slideOn, forKey: .slideOn); try c.encode(slideDistance, forKey: .slideDistance)
        try c.encode(slideMs, forKey: .slideMs)
        try c.encode(riseOn, forKey: .riseOn); try c.encode(riseDistance, forKey: .riseDistance)
        try c.encode(bobDistance, forKey: .bobDistance); try c.encode(riseMs, forKey: .riseMs)
        try c.encode(wiggleOn, forKey: .wiggleOn); try c.encode(wiggleHeight, forKey: .wiggleHeight)
        try c.encode(wiggleCount, forKey: .wiggleCount); try c.encode(wiggleMs, forKey: .wiggleMs)
        try c.encode(blurOn, forKey: .blurOn); try c.encode(blurRadius, forKey: .blurRadius)
        try c.encode(blurMs, forKey: .blurMs)
        try c.encode(growOn, forKey: .growOn); try c.encode(growFromPercent, forKey: .growFromPercent)
        try c.encode(growMs, forKey: .growMs)
        try c.encode(typewriterOn, forKey: .typewriterOn)
        try c.encode(typewriterMsPerCharacter, forKey: .typewriterMsPerCharacter)
        try c.encode(typewriterMaxMs, forKey: .typewriterMaxMs)
        try c.encode(decodeOn, forKey: .decodeOn); try c.encode(decodeMsPerLetter, forKey: .decodeMsPerLetter)
        try c.encode(decodeMaxMs, forKey: .decodeMaxMs); try c.encode(decodeScrambleMs, forKey: .decodeScrambleMs)
        try c.encode(decodeCharacters, forKey: .decodeCharacters)
        try c.encode(colorFadeOn, forKey: .colorFadeOn); try c.encode(colorFadeColor, forKey: .colorFadeColor)
        try c.encode(colorFadeCustom, forKey: .colorFadeCustom)
        try c.encode(colorFadeMsPerLetter, forKey: .colorFadeMsPerLetter)
        try c.encode(colorFadeMaxMs, forKey: .colorFadeMaxMs); try c.encode(colorFadeMs, forKey: .colorFadeMs)
        try c.encode(hangOn, forKey: .hangOn); try c.encode(hangDrop, forKey: .hangDrop)
        try c.encode(hangBob, forKey: .hangBob); try c.encode(hangSwing, forKey: .hangSwing)
        try c.encode(hangMsPerLetter, forKey: .hangMsPerLetter); try c.encode(hangMaxMs, forKey: .hangMaxMs)
        try c.encode(hangMs, forKey: .hangMs)
        try c.encode(particlesOn, forKey: .particlesOn); try c.encode(particleShapes, forKey: .particleShapes)
        try c.encode(particleColorA, forKey: .particleColorA); try c.encode(particleColorB, forKey: .particleColorB)
        try c.encode(particleDensity, forKey: .particleDensity); try c.encode(particleSize, forKey: .particleSize)
        try c.encode(particleSizeVariation, forKey: .particleSizeVariation); try c.encode(particleSpeed, forKey: .particleSpeed)
        try c.encode(particleGravity, forKey: .particleGravity); try c.encode(particleDirection, forKey: .particleDirection)
        try c.encode(particleSpread, forKey: .particleSpread); try c.encode(particleFlutter, forKey: .particleFlutter)
        try c.encode(particleSpin, forKey: .particleSpin); try c.encode(particleLifeMs, forKey: .particleLifeMs)
        try c.encode(particleFadeMs, forKey: .particleFadeMs); try c.encode(particleEmitMs, forKey: .particleEmitMs)
        try c.encode(particleTrickle, forKey: .particleTrickle); try c.encode(particleRoom, forKey: .particleRoom)
        try c.encode(particleGravityDirection, forKey: .particleGravityDirection)
        try c.encode(flickerOn, forKey: .flickerOn); try c.encode(flickerCount, forKey: .flickerCount)
        try c.encode(flickerMs, forKey: .flickerMs); try c.encode(flickerMsPerLetter, forKey: .flickerMsPerLetter)
        try c.encode(flickerMaxMs, forKey: .flickerMaxMs); try c.encode(flickerRandomness, forKey: .flickerRandomness)
        try c.encode(waveOn, forKey: .waveOn); try c.encode(waveHeight, forKey: .waveHeight)
        try c.encode(waveCount, forKey: .waveCount); try c.encode(waveMs, forKey: .waveMs)
        try c.encode(waveMsPerLetter, forKey: .waveMsPerLetter); try c.encode(waveMaxMs, forKey: .waveMaxMs)
        try c.encode(assembleOn, forKey: .assembleOn); try c.encode(assembleDistance, forKey: .assembleDistance)
        try c.encode(assembleSpin, forKey: .assembleSpin); try c.encode(assembleMs, forKey: .assembleMs)
        try c.encode(assembleMsPerLetter, forKey: .assembleMsPerLetter); try c.encode(assembleMaxMs, forKey: .assembleMaxMs)
        try c.encode(glowOn, forKey: .glowOn); try c.encode(glowColor, forKey: .glowColor)
        try c.encode(glowRadius, forKey: .glowRadius); try c.encode(glowMs, forKey: .glowMs)
        try c.encode(glowMsPerLetter, forKey: .glowMsPerLetter); try c.encode(glowMaxMs, forKey: .glowMaxMs)
        try c.encode(phaseOn, forKey: .phaseOn); try c.encode(phaseEchoes, forKey: .phaseEchoes)
        try c.encode(phaseScale, forKey: .phaseScale); try c.encode(phaseBlur, forKey: .phaseBlur)
        try c.encode(phaseMs, forKey: .phaseMs); try c.encode(phaseMsPerLetter, forKey: .phaseMsPerLetter)
        try c.encode(phaseMaxMs, forKey: .phaseMaxMs)
        try c.encode(rippleOn, forKey: .rippleOn); try c.encode(rippleStrength, forKey: .rippleStrength)
        try c.encode(rippleWaves, forKey: .rippleWaves); try c.encode(rippleMs, forKey: .rippleMs)
        try c.encode(rippleMsPerLetter, forKey: .rippleMsPerLetter); try c.encode(rippleMaxMs, forKey: .rippleMaxMs)
        try c.encode(pawsOn, forKey: .pawsOn); try c.encode(pawLettersPerStep, forKey: .pawLettersPerStep)
        try c.encode(pawStepMs, forKey: .pawStepMs); try c.encode(pawMaxMs, forKey: .pawMaxMs)
        try c.encode(pawSize, forKey: .pawSize); try c.encode(pawLingerMs, forKey: .pawLingerMs)
        try c.encode(pawTrail, forKey: .pawTrail); try c.encode(pawTrailOpacity, forKey: .pawTrailOpacity)
        try c.encode(pawSpread, forKey: .pawSpread)
        try c.encode(imprintOn, forKey: .imprintOn); try c.encode(imprintFromPercent, forKey: .imprintFromPercent)
        try c.encode(imprintDepth, forKey: .imprintDepth); try c.encode(imprintMs, forKey: .imprintMs)
        try c.encode(imprintMsPerLetter, forKey: .imprintMsPerLetter); try c.encode(imprintMaxMs, forKey: .imprintMaxMs)
        try c.encode(finalColorOn, forKey: .finalColorOn); try c.encode(finalColor, forKey: .finalColor)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// True when nothing is switched on (the suggestion appears at once).
    public var isEmpty: Bool {
        !(fadeOn || slideOn || riseOn || wiggleOn || blurOn || growOn || typewriterOn || decodeOn || colorFadeOn
          || hangOn || particlesOn || flickerOn || waveOn || assembleOn || glowOn || phaseOn || rippleOn
          || pawsOn || imprintOn)
    }

    /// The built-in styles' tuned recipes.
    public static func preset(_ style: PopInAnimation) -> PopInRecipe {
        var r = PopInRecipe()
        switch style {
        case .none, .custom:
            break
        case .fade:
            r.fadeOn = true; r.fadeMs = 120
        case .fadeSlide:
            r.fadeOn = true; r.fadeMs = 160
            r.slideOn = true; r.slideDistance = -6; r.slideMs = 160
        case .typewriter:
            r.typewriterOn = true
        case .floatUp:
            r.fadeOn = true; r.fadeMs = 230
            r.riseOn = true; r.riseDistance = 4; r.bobDistance = 1; r.riseMs = 380
        case .wiggle:
            r.fadeOn = true; r.fadeMs = 190
            r.wiggleOn = true; r.wiggleHeight = 1.6; r.wiggleCount = 2.5; r.wiggleMs = 550
        case .materialize:
            r.fadeOn = true; r.fadeMs = 240
            r.blurOn = true; r.blurRadius = 3.5; r.blurMs = 300
        case .decode:
            r.decodeOn = true; r.decodeMsPerLetter = 30; r.decodeMaxMs = 500; r.decodeScrambleMs = 25
            r.decodeCharacters = .katakana
            r.colorFadeOn = true; r.colorFadeColor = .green; r.colorFadeMs = 350
        case .wisteria:
            r.fadeOn = true; r.fadeMs = 250
            r.colorFadeOn = true; r.colorFadeColor = .custom; r.colorFadeCustom = StoredColor(hex: 0xB88CF2)
            r.colorFadeMs = 700
            r.hang(maxMs: 500)
            r.particles(.petal, .blossom, from: 0xE0CCFA, to: 0x8554CC, size: 4, variation: 40)
        case .autumn:
            r.colorFadeOn = true; r.colorFadeColor = .custom; r.colorFadeCustom = StoredColor(hex: 0xFD9219)
            r.colorFadeMs = 500
            r.hang(maxMs: 700)
            r.particles(.petal, .leaf, from: 0xFF0000, to: 0xFEED00, density: 0.3, size: 5, variation: 50)
        case .winter:
            r.colorFadeOn = true; r.colorFadeColor = .custom; r.colorFadeCustom = StoredColor(hex: 0xACF1EB)
            r.colorFadeMs = 590
            r.hang(maxMs: 700, swing: 16)
            r.particles(.snowflake, from: 0xB9F8F2, to: 0x00FAFF, density: 0.2, size: 7, variation: 50,
                        speed: 6, spread: 75, flutter: 7, spin: 80, lifeMs: 900)
            r.particleEmitMs = 750; r.particleTrickle = 2
        case .neon:
            r.flickerOn = true; r.flickerCount = 3; r.flickerMs = 450; r.flickerMsPerLetter = 10; r.flickerMaxMs = 550
            r.colorFadeOn = true; r.colorFadeColor = .custom; r.colorFadeCustom = StoredColor(hex: 0xFF3FD2)
            r.colorFadeMs = 900
            r.glowOn = true; r.glowColor = StoredColor(hex: 0xFF3FD2); r.glowRadius = 6; r.glowMs = 900
            r.particles(.dot, .square, from: 0xFFFFFF, to: 0xFF3FD2, density: 0.15, size: 2, variation: 40,
                        speed: 30, spread: 140, flutter: 0, spin: 0, lifeMs: 500)
            r.particleGravity = 120; r.particleFadeMs = 250; r.particleRoom = 22
        case .ocean:
            r.waveOn = true; r.waveHeight = 3; r.waveCount = 1.5; r.waveMs = 800; r.waveMsPerLetter = 30; r.waveMaxMs = 600
            r.colorFadeOn = true; r.colorFadeColor = .custom; r.colorFadeCustom = StoredColor(hex: 0x2FA4FF)
            r.colorFadeMs = 700
            r.particles(.bubble, from: 0xBDEBFF, to: 0x3F9DFF, density: 0.2, size: 5, variation: 50,
                        speed: 4, spread: 60, flutter: 3, spin: 0, lifeMs: 1600)
            r.particleGravity = 18; r.particleGravityDirection = 180; r.particleDirection = 180
        case .stardust:
            r.assembleOn = true; r.assembleDistance = 14; r.assembleSpin = 120; r.assembleMs = 550
            r.assembleMsPerLetter = 25; r.assembleMaxMs = 500
            r.colorFadeOn = true; r.colorFadeColor = .custom; r.colorFadeCustom = StoredColor(hex: 0xFFD45E)
            r.colorFadeMs = 600
            r.particles(.sparkle, .star, from: 0xFFF6CF, to: 0xFFC53D, density: 0.3, size: 5, variation: 50,
                        speed: 8, spread: 360, flutter: 1, spin: 200, lifeMs: 900)
            r.particleGravity = 6
        case .ember:
            r.glowOn = true; r.glowColor = StoredColor(hex: 0xFF8A1F); r.glowRadius = 6; r.glowMs = 900
            r.glowMsPerLetter = 30; r.glowMaxMs = 600
            r.colorFadeOn = true; r.colorFadeColor = .custom; r.colorFadeCustom = StoredColor(hex: 0xFF6A00)
            r.colorFadeMs = 900
            r.particles(.dot, from: 0xFFD27A, to: 0xFF3B00, density: 0.25, size: 3, variation: 50,
                        speed: 10, spread: 50, flutter: 2, spin: 0, lifeMs: 1300)
            r.particleGravity = 30; r.particleGravityDirection = 135; r.particleDirection = 180
            r.particleEmitMs = 1500; r.particleTrickle = 3
        case .spooky:
            r.rippleOn = true; r.rippleStrength = 2; r.rippleWaves = 1.5; r.rippleMs = 800
            r.rippleMsPerLetter = 30; r.rippleMaxMs = 600
            r.glowOn = true; r.glowColor = StoredColor(hex: 0x7A6BFF); r.glowRadius = 5; r.glowMs = 800
            r.colorFadeOn = true; r.colorFadeColor = .custom; r.colorFadeCustom = StoredColor(hex: 0x94DE98)
            r.colorFadeMs = 900
            r.particles(.wisp, .mist, from: 0xF4F1FF, to: 0x8C7DFF, density: 0.2, size: 6, variation: 40,
                        speed: 2, spread: 50, flutter: 3, spin: 0, lifeMs: 1700)
            r.particleGravity = 10; r.particleGravityDirection = 180; r.particleDirection = 180
            r.particleFadeMs = 700
            r.particleEmitMs = 1500; r.particleTrickle = 1.5
            r.finalColor = StoredColor(hex: 0x988EDB)
        case .paws:
            r.pawsOn = true; r.pawLettersPerStep = 4; r.pawStepMs = 100; r.pawMaxMs = 600
            r.pawSize = 13; r.pawLingerMs = 450
            r.imprintOn = true; r.imprintFromPercent = 120; r.imprintDepth = 70; r.imprintMs = 450
        }
        // Styles with a color of their own settle in it (with Color set to Follow effect): their Color
        // fade color, or Matrix's green.
        switch style {
        case .decode:
            r.finalColorOn = true; r.finalColor = StoredColor(red: 0.2, green: 0.95, blue: 0.4)
        case .wisteria, .autumn, .winter, .neon, .ocean, .stardust, .ember:
            r.finalColorOn = true; r.finalColor = r.colorFadeCustom
        case .spooky:
            // Settles in lavender, not its pale green flash.
            r.finalColorOn = true
        default:
            break
        }
        return r
    }

    /// The seasonal styles' hang: drop 5 pt, bob 1 pt, 40 ms a letter, settle 400 ms.
    private mutating func hang(maxMs: Double, swing: Double = 10) {
        hangOn = true
        hangDrop = 5; hangBob = 1; hangSwing = swing
        hangMsPerLetter = 40; hangMaxMs = maxMs; hangMs = 400
    }

    /// The seasonal styles' particles: pop-in only, falling straight down, 500 ms fade-out, 30 pt room.
    private mutating func particles(_ shapes: ParticleShape..., from: UInt32, to: UInt32, density: Double = 0.5,
                                    size: Double, variation: Double, speed: Double = 12, spread: Double = 50,
                                    flutter: Double = 3, spin: Double = 120, lifeMs: Double = 1400) {
        particlesOn = true
        particleShapes = shapes
        particleColorA = StoredColor(hex: from); particleColorB = StoredColor(hex: to)
        particleDensity = density; particleSize = size; particleSizeVariation = variation
        particleSpeed = speed; particleGravity = 25; particleGravityDirection = 0; particleDirection = 0
        particleSpread = spread
        particleFlutter = flutter; particleSpin = spin; particleLifeMs = lifeMs; particleFadeMs = 500
        particleEmitMs = 0; particleRoom = 30
    }

    /// A custom recipe's starting point: a fade and a small rise.
    public static let customDefault: PopInRecipe = {
        var r = PopInRecipe()
        r.fadeOn = true; r.fadeMs = 200
        r.riseOn = true; r.riseDistance = 4; r.bobDistance = 1; r.riseMs = 400
        return r
    }()
}

/// Where the suggestion's color comes from (Settings → Appearance).
public enum SuggestionColorChoice: String, Codable, Sendable, CaseIterable {
    /// The effect's final color (`PopInRecipe.finalColor`); Match text when it has none.
    case followEffect
    /// The field's own text color (the original behavior).
    case matchText
    case grey
    /// The system accent color.
    case accent
    /// `AppearanceSettings.customColor`.
    case custom
}

/// An sRGB color as stored in settings.json.
public struct StoredColor: Codable, Sendable, Equatable {
    public var red, green, blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
    public var rgba: RGBAColor { RGBAColor(red: red, green: green, blue: blue) }
    /// From 0xRRGGBB, as "Copy values" writes them.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Settings → Appearance: how suggestions animate in and how they're colored. Global; the per-app
/// "Always grey" still forces grey.
public struct AppearanceSettings: Codable, Sendable, Equatable {
    public var animation: PopInAnimation
    public var color: SuggestionColorChoice
    public var customColor: StoredColor
    /// Suggestion strength, `opacityRange`; 0.5 is the original look.
    public var opacity: Double
    /// Testing: slider edits to the built-in styles, by `PopInAnimation` raw value. A style that
    /// isn't here uses `PopInRecipe.preset`.
    public var presetTuning: [String: PopInRecipe]
    /// The "Custom" style's effects.
    public var customRecipe: PopInRecipe
    /// Bumped by one-time migrations of saved appearance settings (see `HunchSettingsStore`): 1 = Follow
    /// effect and final colors exist.
    public var version: Int

    public static let opacityRange: ClosedRange<Double> = 0.2...1.0

    public init(animation: PopInAnimation = .none, color: SuggestionColorChoice = .followEffect,
                customColor: StoredColor = StoredColor(red: 0.55, green: 0.35, blue: 0.85), opacity: Double = 0.5,
                presetTuning: [String: PopInRecipe] = [:], customRecipe: PopInRecipe = .customDefault,
                version: Int = AppearanceSettings.currentVersion) {
        self.animation = animation
        self.color = color
        self.customColor = customColor
        self.opacity = opacity
        self.presetTuning = presetTuning
        self.customRecipe = customRecipe
        self.version = version
    }

    public static let currentVersion = 1

    /// The effect's final color for Follow effect, nil when it has none.
    public var effectColor: StoredColor? {
        let r = currentRecipe
        return r.finalColorOn ? r.finalColor : nil
    }

    /// `opacity` kept in range; a non-finite value (a hand-edited file) is the default.
    public var clampedOpacity: Double {
        opacity.isFinite ? min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound) : 0.5
    }

    /// The effects a style plays: the custom recipe, a tuned preset, or the preset as shipped.
    public func recipe(for style: PopInAnimation) -> PopInRecipe {
        if style == .custom { return customRecipe }
        return presetTuning[style.rawValue] ?? .preset(style)
    }

    public var currentRecipe: PopInRecipe { recipe(for: animation) }
}
