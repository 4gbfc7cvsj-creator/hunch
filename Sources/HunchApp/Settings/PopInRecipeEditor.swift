import AppKit
import HunchCore
import HunchOverlay
import SwiftUI

/// Testing aid: sliders for a pop-in's effects. A built-in style shows only the effects it uses;
/// the Custom style shows all of them with on/off switches. `onRelease` fires when a slider is let
/// go or a switch flips (the pane replays the preview).
struct PopInRecipeEditor: View {
    @Binding var recipe: PopInRecipe
    /// Custom: every effect, each with a switch.
    let buildYourOwn: Bool
    let onRelease: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            effect("Fade", on: \.fadeOn) {
                slider("Length", \.fadeMs, 20...1500, step: 10, unit: "ms")
            }
            effect("Slide in", on: \.slideOn) {
                slider("From", \.slideDistance, -40...40, step: 1, unit: "pt",
                       note: "negative = from the left, positive = from the right")
                slider("Length", \.slideMs, 20...1500, step: 10, unit: "ms")
            }
            effect("Rise", on: \.riseOn) {
                slider("From", \.riseDistance, -20...20, step: 0.5, unit: "pt",
                       note: "positive = rises from below, negative = drops from above")
                slider("Bob", \.bobDistance, 0...8, step: 0.25, unit: "pt", note: "overshoot before settling")
                slider("Length", \.riseMs, 50...2000, step: 10, unit: "ms")
            }
            effect("Wiggle", on: \.wiggleOn) {
                slider("Height", \.wiggleHeight, 0...10, step: 0.1, unit: "pt")
                slider("Wobbles", \.wiggleCount, 0.5...8, step: 0.5, unit: "")
                slider("Length", \.wiggleMs, 100...3000, step: 10, unit: "ms")
            }
            effect("Blur", on: \.blurOn) {
                slider("Radius", \.blurRadius, 0...20, step: 0.5, unit: "pt")
                slider("Length", \.blurMs, 20...2000, step: 10, unit: "ms")
            }
            effect("Grow", on: \.growOn) {
                slider("From", \.growFromPercent, 10...300, step: 5, unit: "%",
                       note: "under 100 grows into place, over 100 shrinks into place")
                slider("Length", \.growMs, 20...1500, step: 10, unit: "ms")
            }
            effect("Typewriter", on: \.typewriterOn) {
                slider("Per letter", \.typewriterMsPerCharacter, 5...150, step: 1, unit: "ms")
                slider("At most", \.typewriterMaxMs, 50...4000, step: 50, unit: "ms")
            }
            effect("Scramble", on: \.decodeOn) {
                slider("Per letter", \.decodeMsPerLetter, 5...200, step: 1, unit: "ms", note: "time between letters locking in")
                slider("At most", \.decodeMaxMs, 50...4000, step: 50, unit: "ms")
                slider("Scramble", \.decodeScrambleMs, 10...300, step: 5, unit: "ms", note: "how often a scrambled letter changes")
                picker("Characters", \.decodeCharacters, [(.lettersAndNumbers, "Letters & numbers"),
                                                          (.symbols, "Symbols"), (.katakana, "Katakana")])
            }
            effect("Color fade", on: \.colorFadeOn) {
                picker("Color", \.colorFadeColor, [(.bright, "Bright"), (.green, "Green"), (.custom, "Custom")])
                if recipe.colorFadeColor == .custom {
                    HStack {
                        Text("Custom").frame(width: 80, alignment: .leading)
                        ColorPicker("Custom", selection: customFadeColor, supportsOpacity: false).labelsHidden()
                    }
                }
                if PopIn.sweepPace(recipe) != .colorFade {
                    Text(recipe.decodeOn ? "Follows Scramble: each letter fades once it locks in."
                         : recipe.flickerOn ? "Follows Flicker: each letter fades once it stays lit."
                         : "Follows \(PopIn.sweepPace(recipe).name): each letter fades as it starts.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    slider("Per letter", \.colorFadeMsPerLetter, 5...200, step: 1, unit: "ms",
                           note: "time between letters starting to fade, left to right")
                    slider("At most", \.colorFadeMaxMs, 0...4000, step: 50, unit: "ms",
                           note: "0 = every letter at once")
                }
                slider("Fade", \.colorFadeMs, 20...2000, step: 10, unit: "ms",
                       note: "how long a letter takes to fade to the normal color")
            }
            effect("Paw walk", on: \.pawsOn) {
                slider("Per step", \.pawLettersPerStep, 1...8, step: 1, unit: "letters",
                       note: "letters each step reveals: more = fewer, calmer steps")
                slider("Step", \.pawStepMs, 30...400, step: 5, unit: "ms", note: "time between steps")
                slider("At most", \.pawMaxMs, 0...4000, step: 50, unit: "ms", note: "steps quicken to fit; 0 = all at once")
                slider("Spread", \.pawSpread, 0...100, step: 5, unit: "%",
                       note: "a step's letters ripple out over this much of the step; 0 = all at once")
                slider("Size", \.pawSize, 3...16, step: 0.5, unit: "pt")
                picker("Prints", \.pawTrail, [(.fourPaws, "Four paws"), (.faded, "Faded trail")])
                if recipe.pawTrail == .faded {
                    slider("Linger", \.pawLingerMs, 0...3000, step: 10, unit: "ms",
                           note: "how long a print stays before it fades to the trail")
                    slider("Trail", \.pawTrailOpacity, 0...100, step: 5, unit: "%",
                           note: "how strong the prints left behind are")
                } else {
                    Text("Only the cat's four paws show: each print lifts as the next step after them lands.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            effect("Imprint", on: \.imprintOn) {
                slider("From", \.imprintFromPercent, 100...300, step: 5, unit: "%", note: "starting size, stamped down to its own")
                slider("Depth", \.imprintDepth, 0...100, step: 5, unit: "%", note: "how pressed into the page it looks")
                pace(.imprint, \.imprintMsPerLetter, \.imprintMaxMs)
                slider("Settle", \.imprintMs, 100...3000, step: 10, unit: "ms", note: "how long one letter takes to stamp and settle")
            }
            effect("Hang", on: \.hangOn) {
                slider("Drop", \.hangDrop, -20...20, step: 0.5, unit: "pt",
                       note: "positive = drops from above, negative = rises from below")
                slider("Bob", \.hangBob, 0...8, step: 0.25, unit: "pt", note: "dip past its place before settling")
                slider("Swing", \.hangSwing, 0...45, step: 1, unit: "°", note: "first tilt, hinged at the letter's top")
                pace(.hang, \.hangMsPerLetter, \.hangMaxMs)
                slider("Settle", \.hangMs, 100...3000, step: 10, unit: "ms", note: "how long one letter takes to drop and settle")
            }
            effect("Phase", on: \.phaseOn) {
                slider("Echoes", \.phaseEchoes, 1...6, step: 1, unit: "", note: "afterimages that shrink into each letter")
                slider("From", \.phaseScale, 100...400, step: 10, unit: "%", note: "the outermost one's starting size")
                slider("Blur", \.phaseBlur, 0...10, step: 0.5, unit: "pt", note: "the outermost one's starting softness")
                pace(.phase, \.phaseMsPerLetter, \.phaseMaxMs)
                slider("Surface", \.phaseMs, 100...3000, step: 10, unit: "ms", note: "how long one letter takes to come through")
            }
            effect("Ripple", on: \.rippleOn) {
                slider("Strength", \.rippleStrength, 0...8, step: 0.25, unit: "pt", note: "how far the wave bends a letter at first")
                slider("Waves", \.rippleWaves, 0.5...4, step: 0.25, unit: "", note: "across a letter's height")
                pace(.ripple, \.rippleMsPerLetter, \.rippleMaxMs)
                slider("Calm", \.rippleMs, 100...3000, step: 10, unit: "ms", note: "how long one letter takes to straighten")
            }
            effect("Assemble", on: \.assembleOn) {
                slider("From", \.assembleDistance, 0...60, step: 1, unit: "pt", note: "how far away letters start, each from its own direction")
                slider("Spin", \.assembleSpin, 0...720, step: 10, unit: "°", note: "how far a letter turns on the way in")
                pace(.assemble, \.assembleMsPerLetter, \.assembleMaxMs)
                slider("Arrive", \.assembleMs, 50...3000, step: 10, unit: "ms", note: "how long one letter takes to fly in")
            }
            effect("Wave", on: \.waveOn) {
                slider("Height", \.waveHeight, -10...10, step: 0.25, unit: "pt", note: "first bob; negative = dips first")
                slider("Bobs", \.waveCount, 0.5...6, step: 0.5, unit: "", note: "per letter, dying away")
                pace(.wave, \.waveMsPerLetter, \.waveMaxMs, note: "time between letters: longer = a wider ripple")
                slider("Length", \.waveMs, 100...3000, step: 10, unit: "ms", note: "how long one letter bobs")
            }
            effect("Flicker", on: \.flickerOn) {
                slider("Flashes", \.flickerCount, 1...8, step: 1, unit: "", note: "before a letter stays on")
                pace(.flicker, \.flickerMsPerLetter, \.flickerMaxMs)
                slider("Length", \.flickerMs, 50...2000, step: 10, unit: "ms", note: "how long one letter flickers")
                slider("Randomness", \.flickerRandomness, 0...100, step: 5, unit: "%",
                       note: "0 = every letter flickers alike, in step")
            }
            effect("Glow", on: \.glowOn) {
                HStack {
                    Text("Color").frame(width: 80, alignment: .leading)
                    ColorPicker("Glow color", selection: colorBinding(\.glowColor), supportsOpacity: false).labelsHidden()
                }
                slider("Radius", \.glowRadius, 1...20, step: 0.5, unit: "pt", note: "how far the halo spreads")
                pace(.glow, \.glowMsPerLetter, \.glowMaxMs)
                slider("Cool down", \.glowMs, 100...3000, step: 10, unit: "ms", note: "how long one letter glows")
            }
            effect("Particles", on: \.particlesOn) {
                HStack {
                    Text("Shapes").frame(width: 80, alignment: .leading)
                    Menu {
                        ForEach(ParticleShape.allCases, id: \.self) { shape in
                            Toggle(Self.shapeName(shape), isOn: shapeBinding(shape))
                        }
                    } label: {
                        Text(recipe.particleShapes.isEmpty ? "None"
                             : recipe.particleShapes.map(Self.shapeName).joined(separator: ", "))
                    }
                    .fixedSize()
                    Text("every checked shape is mixed in").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Colors").frame(width: 80, alignment: .leading)
                    ColorPicker("From", selection: colorBinding(\.particleColorA), supportsOpacity: false)
                    ColorPicker("To", selection: colorBinding(\.particleColorB), supportsOpacity: false)
                    Text("each particle gets a shade in between").font(.caption).foregroundStyle(.secondary)
                }
                slider("Density", \.particleDensity, 0.05...5, step: 0.05, unit: "/letter",
                       note: "particles per letter on average")
                slider("Size", \.particleSize, 1...20, step: 0.5, unit: "pt")
                slider("Size range", \.particleSizeVariation, 0...95, step: 5, unit: "%", note: "how much sizes vary")
                slider("Speed", \.particleSpeed, 0...150, step: 1, unit: "pt/s", note: "starting speed")
                slider("Direction", \.particleDirection, -180...180, step: 5, unit: "°",
                       note: "starting direction: 0 = down, 90 = right, -90 = left, 180 = up")
                slider("Gravity", \.particleGravity, 0...200, step: 1, unit: "pt/s²", note: "how hard it pulls")
                slider("Pull toward", \.particleGravityDirection, -180...180, step: 5, unit: "°",
                       note: "0 = down, 90 = right, -90 = left, 180 = up")
                slider("Spread", \.particleSpread, 0...360, step: 5, unit: "°", note: "how widely directions fan out")
                slider("Flutter", \.particleFlutter, 0...20, step: 0.5, unit: "pt", note: "side-to-side sway while falling")
                slider("Spin", \.particleSpin, 0...720, step: 10, unit: "°/s")
                slider("Life", \.particleLifeMs, 200...5000, step: 50, unit: "ms", note: "how long a particle lasts")
                slider("Fade out", \.particleFadeMs, 0...3000, step: 50, unit: "ms", note: "fading at the end of its life")
                emitSlider
                if recipe.particleEmitMs > 0 {
                    slider("Trickle", \.particleTrickle, 0.5...30, step: 0.5, unit: "/s", note: "particles per second after the pop-in")
                }
                slider("Room", \.particleRoom, 5...80, step: 1, unit: "pt", note: "how far particles may go; they fade at the edge")
            }
            effect("Final color", on: \.finalColorOn) {
                HStack {
                    Text("Color").frame(width: 80, alignment: .leading)
                    ColorPicker("Final color", selection: colorBinding(\.finalColor), supportsOpacity: false).labelsHidden()
                    Text("what the suggestion settles in with Color set to Follow effect")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !buildYourOwn, recipe.isEmpty {
                Text("Nothing to tune: the suggestion appears at once.").foregroundStyle(.secondary)
            }
            if buildYourOwn {
                Text("Distances are for 13 pt text and scale with the text size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
    }

    static func shapeName(_ shape: ParticleShape) -> String {
        switch shape {
        case .petal: "Petal"
        case .leaf: "Leaf"
        case .star: "Star"
        case .square: "Square"
        case .heart: "Heart"
        case .snowflake: "Snowflake"
        case .dot: "Dot"
        case .blossom: "Blossom"
        case .sparkle: "Sparkle"
        case .bubble: "Bubble"
        case .wisp: "Wisp"
        case .mist: "Mist"
        }
    }

    private func shapeBinding(_ shape: ParticleShape) -> Binding<Bool> {
        Binding(get: { recipe.particleShapes.contains(shape) }, set: { on in
            var shapes = recipe.particleShapes.filter { $0 != shape }
            if on { shapes.append(shape) }
            recipe.particleShapes = ParticleShape.allCases.filter(shapes.contains)
            onRelease()
        })
    }

    private func colorBinding(_ key: WritableKeyPath<PopInRecipe, StoredColor>) -> Binding<Color> {
        Binding(get: {
            let c = recipe[keyPath: key]
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
        }, set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            recipe[keyPath: key] = StoredColor(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                                               blue: Double(ns.blueComponent))
        })
    }

    /// Emit length: 0 = pop-in only, the far end = while the suggestion shows.
    private var emitSlider: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keep going").frame(width: 80, alignment: .leading)
                Slider(value: Binding(get: { min(recipe.particleEmitMs, PopInRecipe.particleEmitWhileShown) },
                                      set: { recipe.particleEmitMs = $0 }),
                       in: 0...PopInRecipe.particleEmitWhileShown, step: 250) { editing in
                    if !editing { onRelease() }
                }
                Text(Self.emitLabel(recipe.particleEmitMs))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            Text("after the pop-in: 0 = stop, far right = while shown").font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 88)
        }
    }

    static func emitLabel(_ ms: Double) -> String {
        if ms <= 0 { return "pop-in" }
        if ms >= PopInRecipe.particleEmitWhileShown { return "shown" }
        return format(ms, unit: "ms")
    }

    private var customFadeColor: Binding<Color> {
        Binding(get: {
            let c = recipe.colorFadeCustom
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
        }, set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            recipe.colorFadeCustom = StoredColor(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                                                 blue: Double(ns.blueComponent))
        })
    }

    @ViewBuilder
    private func effect<Content: View>(_ title: String, on: WritableKeyPath<PopInRecipe, Bool>,
                                       @ViewBuilder content: () -> Content) -> some View {
        if buildYourOwn {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(title, isOn: Binding(get: { recipe[keyPath: on] },
                                            set: { recipe[keyPath: on] = $0; onRelease() }))
                    .fontWeight(.medium)
                if recipe[keyPath: on] { content().padding(.leading, 18) }
            }
        } else if recipe[keyPath: on] {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                content().padding(.leading, 18)
            }
        }
    }

    /// A per-letter effect's sweep: its own sliders when it leads, else a note on what paces it.
    @ViewBuilder
    private func pace(_ me: PopIn.SweepPace, _ perLetter: WritableKeyPath<PopInRecipe, Double>,
                      _ atMost: WritableKeyPath<PopInRecipe, Double>, note: String? = nil) -> some View {
        let leader = PopIn.sweepPace(recipe)
        if leader != me {
            Text("Paced by \(leader.name).").font(.caption).foregroundStyle(.secondary)
        } else {
            slider("Per letter", perLetter, 5...200, step: 1, unit: "ms", note: note)
            slider("At most", atMost, 0...4000, step: 50, unit: "ms", note: "0 = every letter at once")
        }
    }

    private func picker<V: Hashable>(_ label: String, _ key: WritableKeyPath<PopInRecipe, V>,
                                      _ options: [(V, String)]) -> some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            Picker(label, selection: Binding(get: { recipe[keyPath: key] },
                                             set: { recipe[keyPath: key] = $0; onRelease() })) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private func slider(_ label: String, _ key: WritableKeyPath<PopInRecipe, Double>, _ range: ClosedRange<Double>,
                        step: Double, unit: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).frame(width: 80, alignment: .leading)
                Slider(value: Binding(get: { recipe[keyPath: key] }, set: { recipe[keyPath: key] = $0 }),
                       in: range, step: step) { editing in
                    if !editing { onRelease() }
                }
                Text(Self.format(recipe[keyPath: key], unit: unit))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 88)
            }
        }
    }

    /// "160 ms", "-6 pt", "1.25 pt", "2.5".
    static func format(_ value: Double, unit: String) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        if text == "-0" { text = "0" }
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    /// One line per switched-on effect, for pasting back into chat.
    static func summary(_ r: PopInRecipe) -> String {
        var parts: [String] = []
        func f(_ v: Double, _ u: String) -> String { format(v, unit: u) }
        if r.fadeOn { parts.append("fade \(f(r.fadeMs, "ms"))") }
        if r.slideOn { parts.append("slide from \(f(r.slideDistance, "pt")) over \(f(r.slideMs, "ms"))") }
        if r.riseOn { parts.append("rise from \(f(r.riseDistance, "pt")), bob \(f(r.bobDistance, "pt")), over \(f(r.riseMs, "ms"))") }
        if r.wiggleOn { parts.append("wiggle \(f(r.wiggleHeight, "pt")) × \(f(r.wiggleCount, "")) over \(f(r.wiggleMs, "ms"))") }
        if r.blurOn { parts.append("blur \(f(r.blurRadius, "pt")) over \(f(r.blurMs, "ms"))") }
        if r.growOn { parts.append("grow from \(f(r.growFromPercent, "%")) over \(f(r.growMs, "ms"))") }
        if r.decodeOn {
            parts.append("scramble \(f(r.decodeMsPerLetter, "ms"))/letter, at most \(f(r.decodeMaxMs, "ms")), "
                         + "change every \(f(r.decodeScrambleMs, "ms")), \(r.decodeCharacters.rawValue)")
        }
        if r.colorFadeOn {
            var color = r.colorFadeColor.rawValue
            if r.colorFadeColor == .custom {
                let c = r.colorFadeCustom
                color = String(format: "#%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()),
                               Int((c.blue * 255).rounded()))
            }
            let leader = PopIn.sweepPace(r)
            let pace = leader != .colorFade ? "following \(leader.name.lowercased())"
                : "\(f(r.colorFadeMsPerLetter, "ms"))/letter, at most \(f(r.colorFadeMaxMs, "ms"))"
            parts.append("color fade from \(color), \(pace), fade \(f(r.colorFadeMs, "ms"))")
        }
        func hex(_ c: StoredColor) -> String {
            String(format: "#%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()),
                   Int((c.blue * 255).rounded()))
        }
        func pace(_ me: PopIn.SweepPace, _ perLetter: Double, _ atMost: Double) -> String {
            let leader = PopIn.sweepPace(r)
            return leader != me ? "paced by \(leader.name.lowercased())"
                : "\(f(perLetter, "ms"))/letter, at most \(f(atMost, "ms"))"
        }
        if r.hangOn {
            let hangPace = pace(.hang, r.hangMsPerLetter, r.hangMaxMs)
            parts.append("hang drop \(f(r.hangDrop, "pt")), bob \(f(r.hangBob, "pt")), swing \(f(r.hangSwing, "°")), "
                         + "\(hangPace), settle \(f(r.hangMs, "ms"))")
        }
        if r.pawsOn {
            parts.append("paw walk \(f(r.pawLettersPerStep, "")) letters/step, step \(f(r.pawStepMs, "ms")), "
                         + "at most \(f(r.pawMaxMs, "ms")), spread \(f(r.pawSpread, "%")), size \(f(r.pawSize, "pt")), "
                         + (r.pawTrail == .fourPaws ? "four paws"
                            : "faded trail \(f(r.pawTrailOpacity, "%")) after \(f(r.pawLingerMs, "ms"))"))
        }
        if r.imprintOn {
            parts.append("imprint from \(f(r.imprintFromPercent, "%")), depth \(f(r.imprintDepth, "%")), "
                         + "\(pace(.imprint, r.imprintMsPerLetter, r.imprintMaxMs)), settle \(f(r.imprintMs, "ms"))")
        }
        if r.phaseOn {
            parts.append("phase \(f(r.phaseEchoes, "")) echoes from \(f(r.phaseScale, "%")), blur \(f(r.phaseBlur, "pt")), "
                         + "\(pace(.phase, r.phaseMsPerLetter, r.phaseMaxMs)), surface \(f(r.phaseMs, "ms"))")
        }
        if r.rippleOn {
            parts.append("ripple \(f(r.rippleStrength, "pt")) × \(f(r.rippleWaves, "")) waves, "
                         + "\(pace(.ripple, r.rippleMsPerLetter, r.rippleMaxMs)), calm \(f(r.rippleMs, "ms"))")
        }
        if r.assembleOn {
            parts.append("assemble from \(f(r.assembleDistance, "pt")), spin \(f(r.assembleSpin, "°")), "
                         + "\(pace(.assemble, r.assembleMsPerLetter, r.assembleMaxMs)), arrive \(f(r.assembleMs, "ms"))")
        }
        if r.waveOn {
            parts.append("wave \(f(r.waveHeight, "pt")) × \(f(r.waveCount, "")), "
                         + "\(pace(.wave, r.waveMsPerLetter, r.waveMaxMs)), length \(f(r.waveMs, "ms"))")
        }
        if r.flickerOn {
            parts.append("flicker \(f(r.flickerCount, "")) flashes, "
                         + "\(pace(.flicker, r.flickerMsPerLetter, r.flickerMaxMs)), length \(f(r.flickerMs, "ms")), randomness \(f(r.flickerRandomness, "%"))")
        }
        if r.glowOn {
            parts.append("glow \(hex(r.glowColor)) radius \(f(r.glowRadius, "pt")), "
                         + "\(pace(.glow, r.glowMsPerLetter, r.glowMaxMs)), cool down \(f(r.glowMs, "ms"))")
        }
        if r.particlesOn {
            let shapes = r.particleShapes.map(\.rawValue).joined(separator: "+")
            var line = "particles \(shapes.isEmpty ? "none" : shapes) \(hex(r.particleColorA))→\(hex(r.particleColorB)), "
                + "\(f(r.particleDensity, "/letter")), size \(f(r.particleSize, "pt")) ±\(f(r.particleSizeVariation, "%")), "
                + "speed \(f(r.particleSpeed, "pt/s")), gravity \(f(r.particleGravity, "pt/s²")) toward \(f(r.particleGravityDirection, "°")), "
                + "direction \(f(r.particleDirection, "°")) spread \(f(r.particleSpread, "°")), flutter \(f(r.particleFlutter, "pt")), "
                + "spin \(f(r.particleSpin, "°/s")), life \(f(r.particleLifeMs, "ms")), fade out \(f(r.particleFadeMs, "ms")), "
                + "keep going \(emitLabel(r.particleEmitMs))"
            if r.particleEmitMs > 0 { line += " at \(f(r.particleTrickle, "/s"))" }
            parts.append(line + ", room \(f(r.particleRoom, "pt"))")
        }
        if r.finalColorOn { parts.append("final color \(hex(r.finalColor))") }
        if r.typewriterOn { parts.append("typewriter \(f(r.typewriterMsPerCharacter, "ms"))/letter, at most \(f(r.typewriterMaxMs, "ms"))") }
        return parts.isEmpty ? "no effects" : parts.joined(separator: "; ")
    }
}
