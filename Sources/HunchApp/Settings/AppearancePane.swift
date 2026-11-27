import AppKit
import HunchCore
import HunchOverlay
import HunchSettingsStore
import SwiftUI

/// Appearance: how suggestions pop in, their color and strength, with a live preview.
struct AppearancePane: View {
    let model: SettingsModel
    /// Bumped to replay the preview's pop-in.
    @State private var replay = 0
    /// The selected style's sliders are open (closed again when another style is picked).
    @State private var adjusting = false

    private var appearance: AppearanceSettings { model.settings.appearance }

    var body: some View {
        Form {
            Section {
                AppearancePreview(appearance: appearance, replay: replay)
                .searchAnchor("appearance.preview")
                    .onTapGesture { replay += 1 }
            } header: {
                HStack {
                    Text("Preview")
                    Spacer()
                    Button("Replay") { replay += 1 }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            } footer: {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, appearance.animation != .none {
                    FooterText("Reduce Motion is on in Accessibility settings, so every animation plays as a plain fade.")
                }
            }

            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.styles, id: \.self) { style in
                        styleRow(style).searchAnchor(SettingsSearch.effectAnchor(style.rawValue))
                        // Custom is its sliders, so they always show; other styles open them with Adjust.
                        if appearance.animation == style, style != .none, adjusting || style == .custom {
                            tuning(style)
                        }
                    }
                } header: {
                    Text(group.title).searchAnchor("appearance.effects")
                }
            }

            Section {
                Picker(selection: model.bind(\.appearance.color)) {
                    Text("Follow effect").tag(SuggestionColorChoice.followEffect)
                    Text("Match text").tag(SuggestionColorChoice.matchText)
                    Text("Grey").tag(SuggestionColorChoice.grey)
                    Text("Accent").tag(SuggestionColorChoice.accent)
                    Text("Custom").tag(SuggestionColorChoice.custom)
                } label: {
                    SettingLabel("Color", info: "Follow effect settles in the chosen effect\u{2019}s final color (set in its "
                                 + "sliders), or matches the text when it has none. Match text uses the color of the "
                                 + "text you\u{2019}re typing.")
                }
                .searchAnchor("appearance.color")
                .pickerStyle(.segmented)
                .onChange(of: appearance.color) { replay += 1 }
                if appearance.color == .custom {
                    ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                }
                LabeledContent("Strength") {
                    HStack {
                        Slider(value: model.bind(\.appearance.opacity),
                               in: AppearanceSettings.opacityRange, step: 0.05)
                        Text("\(Int((appearance.clampedOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .searchAnchor("appearance.strength")
                if appearance.clampedOpacity != 0.5 || appearance.color != .followEffect {
                    Button("Restore default look") {
                        model.set(\.appearance.color, to: .followEffect)
                        model.set(\.appearance.opacity, to: 0.5)
                    }
                }
            } header: {
                Text("Color")
            } footer: {
                FooterText("Tips: Apps, websites and categories with an \u{201C}Own look\u{201D} in "
                           + SettingsLinks.md("Apps & Sites", "apps.look") + " use that instead.")
            }

            Section {
                Toggle(isOn: model.bind(\.effectsForDictation)) {
                    SettingLabel("In dictation", info: "Dictated text plays the effect at the caret, then is pasted when it settles.")
                }
                .searchAnchor("appearance.dictation")
                Toggle(isOn: model.bind(\.effectsForWriteForMe)) {
                    SettingLabel("In Write for me", info: "The draft plays the effect as the words come in.")
                }
                .searchAnchor("appearance.writeForMe")
                Toggle(isOn: model.bind(\.effectsForQuickReplies)) {
                    SettingLabel("In quick replies", info: "Replies play the effect as they appear.")
                }
                .searchAnchor("appearance.quickReplies")
            } header: {
                Text("Also use the effect")
            }

            IconsSection(model: model)
        }
        .formStyle(.grouped)
        .searchScrollTarget("appearance")
    }

    private func styleRow(_ style: PopInAnimation) -> some View {
        let selected = appearance.animation == style
        return HStack {
            Button {
                if !selected { adjusting = false }
                model.set(\.appearance.animation, to: style)
                replay += 1
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.name(style))
                        Text(Self.blurb(style)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Only the selected style can be adjusted; None has nothing to adjust and Custom is always open.
            if selected, style != .none, style != .custom {
                Button(adjusting ? "Done" : "Adjust") { adjusting.toggle() }
            }
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold)
            }
        }
    }

    /// Testing aid: the selected style's sliders, a copy-values button and a reset.
    @ViewBuilder private func tuning(_ style: PopInAnimation) -> some View {
        PopInRecipeEditor(recipe: recipeBinding(style), buildYourOwn: style == .custom) { replay += 1 }
        HStack {
            Button("Copy values") {
                let line = "\(Self.name(style)): \(PopInRecipeEditor.summary(appearance.recipe(for: style)))"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }
            if style != .custom, appearance.presetTuning[style.rawValue] != nil {
                Button("Reset to default") {
                    var a = appearance
                    a.presetTuning[style.rawValue] = nil
                    model.set(\.appearance, to: a)
                    replay += 1
                }
            }
            if style == .custom, appearance.customRecipe != .customDefault {
                Button("Start over") {
                    model.set(\.appearance.customRecipe, to: .customDefault)
                    replay += 1
                }
            }
        }
        .padding(.leading, 12)
    }

    private func recipeBinding(_ style: PopInAnimation) -> Binding<PopInRecipe> {
        Binding(get: { appearance.recipe(for: style) }, set: { recipe in
            var a = appearance
            if style == .custom {
                a.customRecipe = recipe
            } else {
                a.presetTuning[style.rawValue] = recipe == .preset(style) ? nil : recipe
            }
            model.set(\.appearance, to: a)
        })
    }

    private var customColor: Binding<Color> {
        Binding(get: {
            let c = appearance.customColor
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
        }, set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            model.set(\.appearance.customColor, to: StoredColor(red: Double(ns.redComponent),
                                                                 green: Double(ns.greenComponent),
                                                                 blue: Double(ns.blueComponent)))
        })
    }

    private struct Group {
        let title: String
        let styles: [PopInAnimation]
    }

    /// The styles on offer, in order. Fade + slide, Float up and Wiggle left the list (their effects
    /// are in Custom); one saved from an earlier build still shows while it's selected.
    static let effects: [PopInAnimation] = [.none, .fade, .materialize, .typewriter, .spooky, .decode, .neon, .ocean,
                                            .stardust, .ember, .wisteria, .autumn, .winter, .paws, .custom]

    private var groups: [Group] {
        var styles = Self.effects
        if !styles.contains(appearance.animation) { styles.insert(appearance.animation, at: styles.count - 1) }
        return [Group(title: "Effects", styles: styles)]
    }

    static func name(_ style: PopInAnimation) -> String {
        switch style {
        case .none: "None"
        case .fade: "Fade in"
        case .fadeSlide: "Fade + slide"
        case .typewriter: "Typewriter"
        case .floatUp: "Float up"
        case .wiggle: "Wiggle"
        case .materialize: "Materialize"
        case .decode: "Matrix"
        case .wisteria: "Wisteria"
        case .autumn: "Autumn"
        case .winter: "Winter"
        case .neon: "Neon"
        case .ocean: "Ocean"
        case .stardust: "Stardust"
        case .ember: "Ember"
        case .spooky: "Spooky"
        case .paws: "Paws"
        case .custom: "Custom"
        }
    }

    static func blurb(_ style: PopInAnimation) -> String {
        switch style {
        case .none: "Appears at once."
        case .fade: "A quick, soft fade."
        case .fadeSlide: "Fades in while gliding out of the cursor."
        case .typewriter: "Types itself out, letter by letter."
        case .floatUp: "Rises from below the line, bobs once and settles."
        case .wiggle: "Fades in with a few wobbles that die down."
        case .materialize: "Sharpens out of a blur."
        case .decode: "Scrambled code that decodes into the words."
        case .wisteria: "Letters hang down in lilac and settle, shedding petals."
        case .autumn: "Letters hang down in orange and settle, shedding red and gold leaves."
        case .winter: "Letters hang down in icy blue and settle, shedding snowflakes."
        case .neon: "Letters flicker on like a neon sign in hot pink, throwing a few sparks."
        case .ocean: "A ripple runs through the letters in sea blue while bubbles float up."
        case .stardust: "Letters fly in from scattered spots and lock into place in gold, among sparkles."
        case .ember: "Each letter flares with a warm glow that cools, while embers drift up on the wind."
        case .spooky: "Each letter ripples into place, fading from pale green to lavender, while little wisps drift up."
        case .paws: "Calico paws walk along the line, stamping the words into the page."
        case .custom: "Mix your own effects."
        }
    }
}

/// A sample text field with a suggestion that plays the chosen pop-in (drawn in SwiftUI to match
/// the overlay's timings, not by the overlay itself).
struct AppearancePreview: View {
    let appearance: AppearanceSettings
    let replay: Int
    @State private var revealed = Int.max
    @State private var typing: Task<Void, Never>?

    private static let typed = "Thanks for the update, I\u{2019}ll take a look "
    private static let ghost = "before our meeting tomorrow"

    private struct Frame {
        var opacity: Double = 1
        var dx: Double = 0
        var dy: Double = 0
        var blur: Double = 0
        var scale: Double = 1
    }

    private var recipe: PopInRecipe {
        PopIn.effective(appearance.currentRecipe,
                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Any change to the style or its effects replays the preview.
    private struct Trigger: Equatable {
        let replay: Int
        let recipe: PopInRecipe
    }

    private var trigger: Trigger { Trigger(replay: replay, recipe: recipe) }

    var body: some View {
        HStack(spacing: 0) {
            Text(Self.typed).foregroundStyle(.primary)
            Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 16)
            ghostText
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { ghostFrame = $0 }
                .foregroundStyle(ghostColor)
                .keyframeAnimator(initialValue: Frame(), trigger: trigger) { content, f in
                    content.opacity(f.opacity)
                        .scaleEffect(f.scale, anchor: .bottomLeading)
                        .offset(x: f.dx, y: f.dy)
                        .blur(radius: f.blur)
                } keyframes: { _ in
                    keyframes
                }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { fieldSize = $0 }
        .overlay {
            ParticleHost(emitter: particles, room: particleRoom)
                .padding(-particleRoom)
                .allowsHitTesting(false)
        }
        .onChange(of: trigger, initial: true) { startTypewriter(); startDecode(); startParticles() }
        .onDisappear { typing?.cancel(); particles.clear() }
    }

    /// The overlay's colors: grey solid from 50% up, everything else at the chosen strength.
    private var ghostColor: Color {
        let strength = appearance.clampedOpacity
        var choice = appearance.color
        if choice == .followEffect {
            if let c = appearance.effectColor {
                return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: strength)
            }
            choice = .matchText
        }
        switch choice {
        case .matchText, .followEffect: return Color.primary.opacity(strength)
        case .grey: return Color(.sRGB, white: PopIn.grey.red, opacity: min(1, strength * 2))
        case .accent: return Color.accentColor.opacity(strength)
        case .custom:
            let c = appearance.customColor
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: strength)
        }
    }

    /// The overlay's recipe in SwiftUI. SwiftUI's y grows downward and the overlay's upward, so
    /// vertical offsets are flipped.
    @KeyframesBuilder<Frame> private var keyframes: some Keyframes<Frame> {
        let r = recipe
        KeyframeTrack(\Frame.opacity) {
            if r.fadeOn {
                LinearKeyframe(0, duration: 0.001)
                CubicKeyframe(1, duration: r.fadeMs / 1000)
            } else {
                LinearKeyframe(1, duration: 0.001)
            }
        }
        KeyframeTrack(\Frame.dx) {
            if r.slideOn {
                LinearKeyframe(r.slideDistance, duration: 0.001)
                CubicKeyframe(0, duration: r.slideMs / 1000)
            } else {
                LinearKeyframe(0, duration: 0.001)
            }
        }
        KeyframeTrack(\Frame.dy) {
            // Rise and wiggle add up, as in the overlay.
            for (value, time) in Self.verticalPath(r) {
                LinearKeyframe(value, duration: time)
            }
        }
        KeyframeTrack(\Frame.blur) {
            if r.blurOn {
                LinearKeyframe(r.blurRadius, duration: 0.001)
                CubicKeyframe(0, duration: r.blurMs / 1000)
            } else {
                LinearKeyframe(0, duration: 0.001)
            }
        }
        KeyframeTrack(\Frame.scale) {
            if r.growOn {
                LinearKeyframe(max(0.05, r.growFromPercent / 100), duration: 0.001)
                CubicKeyframe(1, duration: r.growMs / 1000)
            } else {
                LinearKeyframe(1, duration: 0.001)
            }
        }
    }

    /// Rise and wiggle sampled on one timeline (SwiftUI offset, down = positive), as
    /// (value, seconds since the previous sample).
    private static func verticalPath(_ r: PopInRecipe) -> [(Double, Double)] {
        guard r.riseOn || r.wiggleOn else { return [(0, 0.001)] }
        let rise = r.riseOn ? PopIn.riseKeyframes(distance: r.riseDistance, bob: r.bobDistance) : nil
        let wiggle = r.wiggleOn ? PopIn.wiggleKeyframes(height: r.wiggleHeight, count: r.wiggleCount) : nil
        let total = max(r.riseOn ? r.riseMs : 0, r.wiggleOn ? r.wiggleMs : 0) / 1000
        let steps = 60
        func sample(_ k: (values: [Double], times: [Double])?, ms: Double, at t: Double) -> Double {
            guard let k else { return 0 }
            let p = min(1, t / (ms / 1000))
            guard let i = k.times.lastIndex(where: { $0 <= p }), i < k.times.count - 1 else { return k.values.last ?? 0 }
            let span = k.times[i + 1] - k.times[i]
            let f = span > 0 ? (p - k.times[i]) / span : 1
            let eased = f * f * (3 - 2 * f)
            return k.values[i] + (k.values[i + 1] - k.values[i]) * eased
        }
        var out: [(Double, Double)] = []
        for i in 0...steps {
            let t = total * Double(i) / Double(steps)
            let up = sample(rise, ms: r.riseMs, at: t) + sample(wiggle, ms: r.wiggleMs, at: t)
            out.append((-up, i == 0 ? 0.001 : total / Double(steps)))
        }
        return out
    }

    // MARK: Particles

    nonisolated private static let space = "preview"
    @State private var particles = ParticleEmitter()
    @State private var ghostFrame = CGRect.zero
    @State private var fieldSize = CGSize.zero
    private static let unit = 14.0 / 13

    private var particleRoom: CGFloat { recipe.particlesOn ? CGFloat(max(5, recipe.particleRoom) * Self.unit) : 0 }

    /// The ghost's letters' middles in the particle view's coords (AppKit: y up, `particleRoom` margin).
    private func particleCenters() -> [CGPoint] {
        let text = Self.ghost
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: Self.previewFont]))
        let utf16 = (text as NSString).length
        let room = particleRoom
        let y = fieldSize.height + room - ghostFrame.midY
        var index = 0
        return text.map { ch in
            let a = CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)
            index += ch.utf16.count
            let b = CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)
            return CGPoint(x: room + ghostFrame.minX + (a + b) / 2, y: y)
        }
    }

    private func startParticles() {
        particles.stopTrickle()
        let r = recipe
        guard r.particlesOn else { particles.clear(); return }
        let count = Self.ghost.count
        let rate = PopIn.sweepRate(r, characters: count)
        let land = PopIn.landDelay(r)
        particles.shed(r, text: Self.ghost, centers: particleCenters(),
                    delays: (0..<count).map { PopIn.letterStart(r, index: $0, rate: rate) + PopIn.letterLandDelay(r, index: $0) },
                    unit: Self.unit)
        let room = particleRoom
        let frame = ghostFrame, height = fieldSize.height
        particles.startTrickle(r, unit: Self.unit, after: rate * Double(count) + land) {
            CGRect(x: room + frame.minX, y: height + room - frame.maxY, width: frame.width, height: frame.height)
        }
    }

    // MARK: Decode

    @State private var decodeStart: Date?
    @State private var decodeEnd: Task<Void, Never>?
    private static let previewFont = NSFont.systemFont(ofSize: 14)
    /// Room above and below the preview's letters for Hang.
    private static let hangRoom: CGFloat = 30

    /// The suggestion: plain, typed out, or mid-scramble / color fade / hang.
    @ViewBuilder private var ghostText: some View {
        if let start = decodeStart, PopIn.isPerLetter(recipe) {
            TimelineView(.animation) { context in
                decodeCanvas(elapsed: context.date.timeIntervalSince(start))
            }
        } else {
            Text(String(Self.ghost.prefix(revealed)))
        }
    }

    /// One scramble / color fade frame, each character centered in the real one's slot (as the
    /// overlay draws it).
    private func decodeCanvas(elapsed: TimeInterval) -> some View {
        let r = recipe
        let text = String(Self.ghost.prefix(revealed))
        let rate = PopIn.sweepRate(r, characters: text.count)
        let locked = elapsed / max(0.0001, rate)
        let frame = r.decodeOn
            ? PopIn.decodeFrame(text, locked: locked, tick: Int(elapsed / max(0.005, r.decodeScrambleMs / 1000)),
                                pool: r.decodeCharacters.pool)
            : Array(text)
        let fadeMs = PopIn.letterFadeMs(r)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: Self.previewFont]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let utf16 = (text as NSString).length
        var slots: [(CGFloat, CGFloat)] = []
        var index = 0
        for ch in text {
            let a = CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)
            index += ch.utf16.count
            slots.append((a, CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)))
        }
        let fadeColor: Color = switch r.colorFadeColor {
        case .bright: ghostColor.opacity(1 / max(0.2, appearance.clampedOpacity))
        case .green: Color(.sRGB, red: 0.2, green: 0.95, blue: 0.4)
        case .custom:
            Color(.sRGB, red: r.colorFadeCustom.red, green: r.colorFadeCustom.green, blue: r.colorFadeCustom.blue)
        }
        let flash: Color? = r.colorFadeOn ? fadeColor : nil
        return Canvas { context, size in
            for (i, ch) in frame.enumerated() where !ch.isWhitespace && i < slots.count {
                let (a, b) = slots[i]
                var t = Text(String(ch)).font(.system(size: 14))
                let tint = PopIn.decodeTint(index: i, locked: locked, rate: rate, fadeMs: fadeMs,
                                            delay: PopIn.letterFadeDelay(r, index: i) + PopIn.letterLag(r, index: i, rate: rate))
                if let flash, tint > 0 { t = t.foregroundColor(ghostColor.mix(with: flash, by: tint)) }
                var c = context
                let at = CGPoint(x: (a + b) / 2, y: size.height / 2)
                if PopIn.hasLetterPose(r) {
                    // As the overlay; SwiftUI's y and turns run the other way.
                    let pose = PopIn.letterPose(r, index: i, t: elapsed - PopIn.letterStart(r, index: i, rate: rate))
                    guard pose.alpha > 0 || pose.echoAlpha > 0 else { continue }
                    c.opacity = pose.alpha
                    c.translateBy(x: pose.dx * Self.unit, y: -pose.dy * Self.unit)
                    if pose.tilt != 0 {
                        // Hinged at the letter's top.
                        let pivot = CGPoint(x: at.x, y: at.y - 7)
                        c.translateBy(x: pivot.x, y: pivot.y)
                        c.rotate(by: .degrees(-pose.tilt))
                        c.translateBy(x: -pivot.x, y: -pivot.y)
                    }
                    if pose.spin != 0 {
                        c.translateBy(x: at.x, y: at.y)
                        c.rotate(by: .degrees(-pose.spin))
                        c.translateBy(x: -at.x, y: -at.y)
                    }
                    if pose.scaleX != 1 || pose.scaleY != 1 {
                        // About the middle of the letter's baseline.
                        let base = CGPoint(x: at.x, y: at.y + 4)
                        c.translateBy(x: base.x, y: base.y)
                        c.scaleBy(x: pose.scaleX, y: pose.scaleY)
                        c.translateBy(x: -base.x, y: -base.y)
                    }
                    if pose.inset > 0.01, pose.alpha > 0 {
                        // Pressed in, as the overlay: a light edge below and a darker letter.
                        var e = c
                        e.opacity = pose.alpha * 0.75 * pose.inset
                        e.draw(Text(String(ch)).font(.system(size: 14)).foregroundColor(.white),
                               at: CGPoint(x: at.x, y: at.y + 0.8 * Self.unit), anchor: .center)
                        let base = tint > 0 && flash != nil ? ghostColor.mix(with: flash!, by: tint) : ghostColor
                        t = t.foregroundColor(base.mix(with: .black, by: 0.3 * pose.inset))
                    }
                    if pose.echoAlpha > 0, pose.echo > 0 {
                        drawEchoes(ch, pose: pose, recipe: r, base: t, at: at, in: c)
                    }
                    guard pose.alpha > 0 else { continue }
                    let rippled = pose.ripple > 0.05
                    if pose.glow > 0 {
                        let gc = Color(.sRGB, red: r.glowColor.red, green: r.glowColor.green, blue: r.glowColor.blue)
                        var g = c
                        g.addFilter(.shadow(color: gc.opacity(min(1, pose.glow * 1.2)),
                                            radius: r.glowRadius * Self.unit * pose.glow / 2))
                        g.opacity = pose.alpha * pose.glow
                        let hot = Text(String(ch)).font(.system(size: 14)).foregroundColor(gc)
                        for _ in 0..<2 {
                            if rippled {
                                // Warped like the letter, as one layer so the halo isn't cut into bands.
                                g.drawLayer { drawRippled(hot, pose: pose, waves: r.rippleWaves, at: at, in: $0) }
                            } else {
                                g.draw(hot, at: at, anchor: .center)
                            }
                        }
                    }
                    if rippled {
                        drawRippled(t, pose: pose, waves: r.rippleWaves, at: at, in: c)
                        continue
                    }
                }
                c.draw(t, at: at, anchor: .center)
            }
            drawPaws(PopIn.pawPrints(r, characters: text.count, shift: 0, elapsed: elapsed, rate: rate),
                     slots: slots, recipe: r, mid: size.height / 2, in: context)
        }
        .frame(width: ceil(width), height: 18 + 2 * Self.hangRoom)
        .padding(.vertical, -Self.hangRoom)
    }

    /// Paw walk's prints, as the overlay draws them (SwiftUI's y and turns run the other way).
    private func drawPaws(_ paws: [PopIn.PawPrint], slots: [(CGFloat, CGFloat)], recipe r: PopInRecipe, mid: CGFloat,
                          in context: GraphicsContext) {
        let s = max(1, r.pawSize) * Self.unit
        let pads = PopIn.pawPads(size: s)
        let rim = max(0.8, s * 0.11)
        func color(_ c: RGBAColor) -> Color { Color(.sRGB, red: c.red, green: c.green, blue: c.blue) }
        for paw in paws where paw.alpha > 0.01 && paw.last < slots.count {
            let x = (slots[paw.first].0 + slots[paw.last].1) / 2
            let y = paw.above ? mid - 9 - s * 0.15 : mid + 7 + s * 0.15
            var outer = context
            outer.opacity = paw.alpha * 0.92
            // One layer, faded as a whole: overlapping fur and pads don't show through each other.
            outer.drawLayer { c in
            var c = c
            c.translateBy(x: x, y: y)
            c.rotate(by: .degrees(90 - paw.tilt))
            c.scaleBy(x: paw.scale, y: paw.scale)
            func ellipses(_ grow: Double) -> Path {
                var path = Path()
                for p in pads {
                    path.addEllipse(in: CGRect(x: p.x - p.rx - grow, y: -p.y - p.ry - grow,
                                               width: 2 * (p.rx + grow), height: 2 * (p.ry + grow)))
                }
                return path
            }
            c.fill(Path(ellipseIn: CGRect(x: -0.36 * s, y: -0.20 * s, width: 0.72 * s, height: 0.62 * s)),
                   with: .color(color(PopIn.pawColors[paw.color % PopIn.pawColors.count])))
            c.fill(ellipses(rim), with: .color(color(PopIn.pawColors[paw.color % PopIn.pawColors.count])))
            c.fill(ellipses(0), with: .color(color(PopIn.beanPink)))
            }
        }
    }

    /// Phase's afterimages, as the overlay draws them: outer ones larger, fainter and softer.
    private func drawEchoes(_ ch: Character, pose: PopIn.LetterPose, recipe r: PopInRecipe, base: Text, at: CGPoint,
                            in context: GraphicsContext) {
        let n = max(1, Int(r.phaseEchoes.rounded()))
        let halo: Color = r.glowOn
            ? Color(.sRGB, red: r.glowColor.red, green: r.glowColor.green, blue: r.glowColor.blue) : ghostColor
        for k in (1...n).reversed() {
            let f = Double(k) / Double(n)
            let scale = 1 + (max(1, r.phaseScale / 100) - 1) * pose.echo * f
            var e = context
            // The pose's own opacity is the letter's; the echoes have theirs.
            e.opacity = pose.echoAlpha * (0.6 - 0.3 * f)
            let blur = max(0, r.phaseBlur) * Self.unit * pose.echo * f
            e.addFilter(.shadow(color: halo.opacity(min(1, e.opacity * 1.6)), radius: 1 + blur * scale))
            e.addFilter(.blur(radius: blur * 0.6))
            e.translateBy(x: at.x, y: at.y)
            e.scaleBy(x: scale, y: scale)
            e.translateBy(x: -at.x, y: -at.y)
            e.draw(base, at: at, anchor: .center)
        }
    }

    /// Ripple, as the overlay draws it: thin bands of the letter pushed sideways along a sine wave.
    private func drawRippled(_ text: Text, pose: PopIn.LetterPose, waves: Double, at: CGPoint,
                             in context: GraphicsContext) {
        let bands = 14, height = 20.0
        let band = height / Double(bands)
        let top = at.y - height / 2
        let strength = pose.ripple * Self.unit
        for j in 0..<bands {
            // SwiftUI's y runs down; the wave runs up the letter as in the overlay.
            let along = 1 - (Double(j) + 0.5) / Double(bands)
            let dx = strength * sin(pose.ripplePhase + waves * 2 * .pi * along)
            var c = context
            c.clip(to: Path(CGRect(x: at.x - 20, y: top + Double(j) * band - 0.25, width: 40, height: band + 0.5)))
            c.draw(text, at: CGPoint(x: at.x + dx, y: at.y), anchor: .center)
        }
    }

    private func startDecode() {
        decodeEnd?.cancel()
        guard PopIn.isPerLetter(recipe) else { decodeStart = nil; return }
        decodeStart = Date()
        let r = recipe, count = Self.ghost.count
        let duration = PopIn.perLetterDuration(r, characters: count)
        decodeEnd = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.05))
            if !Task.isCancelled { decodeStart = nil }
        }
    }

    private func startTypewriter() {
        typing?.cancel()
        guard recipe.typewriterOn else { revealed = .max; return }
        let count = Self.ghost.count
        let step = PopIn.typewriterDuration(recipe, characters: count) / Double(count)
        revealed = 0
        typing = Task { @MainActor in
            for i in 1...count {
                try? await Task.sleep(for: .seconds(step))
                if Task.isCancelled { return }
                revealed = i
            }
        }
    }
}

/// Hosts a `ParticleEmitter`'s view, keeping it the size SwiftUI gives this view.
private struct ParticleHost: NSViewRepresentable {
    let emitter: ParticleEmitter
    let room: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = LayoutView()
        v.addSubview(emitter.view)
        v.onLayout = { [weak emitter] bounds in
            emitter?.place(frame: bounds, screenOrigin: .zero, edge: max(4, room * 0.5))
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? LayoutView)?.onLayout = { [weak emitter] bounds in
            emitter?.place(frame: bounds, screenOrigin: .zero, edge: max(4, room * 0.5))
        }
        nsView.needsLayout = true
    }

    final class LayoutView: NSView {
        var onLayout: ((CGRect) -> Void)?
        override func layout() {
            super.layout()
            onLayout?(bounds)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
