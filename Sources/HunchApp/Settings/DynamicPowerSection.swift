import HunchCore
import SwiftUI

/// "Dynamic Power Mode" at the top of Settings → Performance & Models: the switch, then (only
/// while it is on) what it uses now, the Language Model and Speech to Text models for Performance and
/// for Efficiency, and the signals with their thresholds.
struct DynamicPowerSection: View {
    @Bindable var model: ModelsPaneModel
    let settings: SettingsModel

    private var dynamic: DynamicPowerSettings { settings.settings.dynamicPower }

    var body: some View {
        Section {
            Toggle(isOn: settings.bind(\.dynamicPower.enabled)) {
                SettingLabel("Dynamic Power Mode", info: "Switches to smaller Efficiency models on low battery or when the Mac is busy, and back "
                     + "to your Performance models when things calm down.\n\nBattery, Low Power Mode, memory and heat "
                     + "are reported by macOS, so watching them costs nothing. GPU load is checked every "
                     + "\(Int(DynamicPower.gpuSampleSeconds)) seconds while a model is loaded. Hunch's own work "
                     + "(suggestions, Write for me, dictation) is left out. It switches to Efficiency right away and "
                     + "back to Performance after a minute of calm.")
            }
            .searchAnchor("model.dynamicPower")
            if dynamic.enabled {
                nowLine
                modelPickers
                signals
            }
        } header: {
            Text("Performance")
        } footer: {
            if dynamic.enabled && !model.dynamicLanguageActive {
                FooterText("The Language Model uses an endpoint, so only Speech to Text follows Dynamic Power Mode.")
            }
        }
    }

    // MARK: Now

    @ViewBuilder private var nowLine: some View {
        LabeledContent("Now") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.dynamicReason == nil ? "Performance" : "Efficiency")
                if let reason = model.dynamicReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Models

    /// The Performance block, then the Efficiency block, each with the Language Model and Speech to
    /// Text dropdowns side by side.
    @ViewBuilder private var modelPickers: some View {
        modeBlock("Performance", efficiency: false)
        modeBlock("Efficiency", efficiency: true)
    }

    private func modeBlock(_ title: String, efficiency: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack(alignment: .top, spacing: 16) {
                column("Language Model") { languagePicker(efficiency: efficiency) }
                column("Speech to Text") { speechPicker(efficiency: efficiency) }
            }
        }
    }

    private func column(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The last dropdown item: opens "Add a model file…" instead of picking.
    private static let addFileTag = "\u{0}add-file"

    @ViewBuilder private func languagePicker(efficiency: Bool) -> some View {
        if !model.dynamicLanguageActive {
            Text("Uses an endpoint").foregroundStyle(.secondary)
        } else if model.dynamicLanguageOptions.isEmpty {
            Button("Add a model file\u{2026}") { model.addFile?(.autocomplete) }.disabled(!model.canDownload)
        } else {
            let sizes = Dictionary(model.rows.map { ($0.id, $0.byteSize) }, uniquingKeysWith: { a, _ in a })
            let options = model.dynamicLanguageOptions.sorted { (sizes[$0] ?? 0) > (sizes[$1] ?? 0) }
            let label = { (id: ModelEntryID) in Self.label(Self.languageName(id), sizes[id]) }
            Picker("", selection: Binding<String>(
                get: {
                    efficiency ? (dynamic.languageEfficiencyModel ?? "") : (model.selected?.relativePath ?? "")
                },
                set: { tag in
                    if tag == Self.addFileTag {
                        // After the menu closes, so the open panel isn't started from inside it.
                        DispatchQueue.main.async { model.addFile?(.autocomplete) }
                    } else if efficiency {
                        settings.set(\.dynamicPower.languageEfficiencyModel, to: tag.isEmpty ? nil : tag)
                    } else if let id = options.first(where: { $0.relativePath == tag }) {
                        model.selected = id
                        model.selectModel(id)
                    }
                })) {
                if efficiency {
                    Text("Automatic (smallest): " + (model.dynamicLanguageEfficiency.map(label) ?? "none")).tag("")
                }
                ForEach(options, id: \.self) { Text(label($0)).tag($0.relativePath) }
                if model.canDownload {
                    Divider()
                    Text("Add a model file\u{2026}").tag(Self.addFileTag)
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder private func speechPicker(efficiency: Bool) -> some View {
        let downloaded = (model.catalog[.speechToText] ?? []).filter { $0.state == .downloaded }
            .sorted { $0.byteSize > $1.byteSize }
        if downloaded.isEmpty {
            Text("None downloaded").foregroundStyle(.secondary)
        } else {
            let label = { (id: String) -> String in
                let row = downloaded.first { $0.id == id }
                return Self.label(row?.name ?? id, row?.byteSize)
            }
            Picker("", selection: Binding<String>(
                get: { efficiency ? (dynamic.speechEfficiencyModel ?? "") : (model.effectiveSpeechModel ?? "") },
                set: { id in
                    if efficiency {
                        settings.set(\.dynamicPower.speechEfficiencyModel, to: id.isEmpty ? nil : id)
                    } else if !id.isEmpty {
                        model.speechSelected = id
                        model.selectSpeechModel(id)
                    }
                })) {
                if efficiency {
                    Text("Automatic (smallest): " + (model.dynamicSpeechEfficiency.map(label) ?? "none")).tag("")
                }
                ForEach(downloaded) { Text(label($0.id)).tag($0.id) }
            }
            .labelsHidden()
        }
    }

    /// "Qwen3-1.7B: 1.1 GB".
    private static func label(_ name: String, _ size: Int64?) -> String {
        guard let size, size > 0 else { return name }
        return "\(name): " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private static func languageName(_ id: ModelEntryID) -> String {
        var file = (id.relativePath as NSString).lastPathComponent
        if file.lowercased().hasSuffix(".gguf") { file = String(file.dropLast(5)) }
        return file
    }

    // MARK: Signals

    /// Percent signals first, then the macOS levels, then Low Power Mode (no threshold).
    @ViewBuilder private var signals: some View {
        signal("Battery level", use: \.dynamicPower.useBattery,
               summary: "Efficiency at \(dynamic.batteryPercent)% or less") {
            Slider(value: percent(\.dynamicPower.batteryPercent), in: 5...95, step: 5) {
                EmptyView()
            } minimumValueLabel: { Text("5%") } maximumValueLabel: { Text("95%") }
        }
        signal("GPU load", use: \.dynamicPower.useGPU,
               summary: "Efficiency at \(dynamic.gpuPercent)% or more") {
            Slider(value: percent(\.dynamicPower.gpuPercent), in: 10...100, step: 5) {
                EmptyView()
            } minimumValueLabel: { Text("10%") } maximumValueLabel: { Text("100%") }
        }
        signal("Memory pressure", use: \.dynamicPower.useMemory,
               summary: "Efficiency at \(dynamic.memoryLevel.rawValue.capitalized)") {
            Slider(value: level(\.dynamicPower.memoryLevel, Self.memoryLevels),
                   in: 0...Double(Self.memoryLevels.count - 1), step: 1) {
                EmptyView()
            } minimumValueLabel: { Text("Warning") } maximumValueLabel: { Text("Critical") }
        }
        signal("Heat", use: \.dynamicPower.useHeat,
               summary: "Efficiency at \(dynamic.heatLevel.rawValue.capitalized)"
                   + (dynamic.heatLevel == .critical ? "" : " or hotter")) {
            Slider(value: level(\.dynamicPower.heatLevel, Self.heatLevels),
                   in: 0...Double(Self.heatLevels.count - 1), step: 1) {
                EmptyView()
            } minimumValueLabel: { Text("Fair") } maximumValueLabel: { Text("Critical") }
        }
        Toggle("Low Power Mode", isOn: settings.bind(\.dynamicPower.useLowPowerMode))
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let memoryLevels: [MemoryPressureLevel] = [.warning, .critical]
    private static let heatLevels: [HeatLevel] = [.fair, .serious, .critical]

    /// A checkbox with the threshold in words beside it, and its slider underneath.
    private func signal(_ title: String, use: WritableKeyPath<HunchSettings, Bool> & Sendable, summary: String,
                        @ViewBuilder slider: () -> some View) -> some View {
        let on = settings.settings[keyPath: use]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(title, isOn: settings.bind(use)).toggleStyle(.checkbox)
                Spacer()
                Text(summary).font(.caption).monospacedDigit().foregroundStyle(on ? .secondary : .tertiary)
            }
            slider().disabled(!on)
        }
    }

    /// An Int percent setting as the slider's Double.
    private func percent(_ key: WritableKeyPath<HunchSettings, Int> & Sendable) -> Binding<Double> {
        Binding(get: { Double(settings.settings[keyPath: key]) },
                set: { v in
                    let next = Int(v.rounded())
                    if next != settings.settings[keyPath: key] { settings.set(key, to: next) }
                })
    }

    /// A level setting as its position among `levels` (a level outside them reads as the nearest end).
    private func level<L: Comparable & Sendable>(_ key: WritableKeyPath<HunchSettings, L> & Sendable,
                                                 _ levels: [L]) -> Binding<Double> {
        Binding(get: {
                    let current = settings.settings[keyPath: key]
                    return Double(levels.firstIndex(of: current) ?? (current < levels[0] ? 0 : levels.count - 1))
                },
                set: { v in
                    let next = levels[min(max(0, Int(v.rounded())), levels.count - 1)]
                    if next != settings.settings[keyPath: key] { settings.set(key, to: next) }
                })
    }
}

/// In place of a model list while Dynamic Power Mode chooses for it.
struct DynamicChoosingNote: View {
    var body: some View {
        Label("Dynamic Power Mode is choosing", systemImage: "bolt.badge.automatic")
            .foregroundStyle(.red)
    }
}
