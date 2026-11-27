import HunchCore
import SwiftUI
import UniformTypeIdentifiers

/// Personalization → About me → Suggestion styles: the ring the style keys step through, laid out
/// as chips in key order (left = previous, right = next), the app's own instructions first. Drag a
/// chip to move it, click it to edit its name, wording, length and whether it's on; + adds one.
/// Built-ins can be reset, any style deleted, deleted built-ins restored from the + menu.
struct SuggestionStylesSection: View {
    let model: SettingsModel
    @State private var selected: String?
    @State private var dragging: String?
    @State private var confirmDelete: SuggestionStyle?

    private var styles: [SuggestionStyle] { model.settings.suggestionStyles }

    private func update(_ change: (inout [SuggestionStyle]) -> Void) {
        var list = styles
        change(&list)
        model.set(\.suggestionStyles, to: list)
    }

    private func update(_ id: String, _ change: (inout SuggestionStyle) -> Void) {
        update { list in
            if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]) }
        }
    }

    var body: some View {
        Section {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chipLabel("App\u{2019}s own", selected: false, on: true, fixed: true)
                            .help("The app\u{2019}s own instructions. The keys pass through here between the last style and the first.")
                        ForEach(styles) { style in chip(style) }
                    }
                    .padding(.vertical, 2)
                }
                // A drop between or beside the chips ends the drag too (the order is already live).
                .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }
                addButton
            }
            .confirmationDialog("Delete \u{201C}\(confirmDelete?.name ?? "")\u{201D}?",
                                isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                presenting: confirmDelete) { style in
                Button("Delete", role: .destructive) {
                    update { $0.removeAll { $0.id == style.id } }
                    if selected == style.id { selected = nil }
                }
            }
            if let id = selected, let style = styles.first(where: { $0.id == id }) {
                editor(style)
            }
        } header: {
            SettingLabel("Suggestion styles", info: "With a suggestion showing, \(chordDescription(model.settings.bindings.styleNext)) redoes it in the style to the right and \(chordDescription(model.settings.bindings.stylePrevious)) in the one to the left; past either end you\u{2019}re back to the app\u{2019}s own instructions. A tag under the caret names the style, with the ones before and after it on either side. A style replaces the app\u{2019}s instructions and How I write, and lasts for the rest of the text box.")
            .searchAnchor("personalization.styles")
        } footer: {
            FooterText("Tips: Click a style to edit it; drag to change the order. Set the keys in "
                       + SettingsLinks.md("Shortcuts", "shortcuts.styleNext") + ".")
        }
    }

    // MARK: Chips

    private func chip(_ style: SuggestionStyle) -> some View {
        chipLabel(style.name.isEmpty ? "Untitled" : style.name, selected: selected == style.id,
                  on: style.enabled && !style.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(dragging == style.id ? 0.4 : 1)
            .contentShape(Capsule())
            .onTapGesture { selected = selected == style.id ? nil : style.id }
            .onDrag {
                dragging = style.id
                return NSItemProvider(object: style.id as NSString)
            }
            .onDrop(of: [.text], delegate: ChipDrop(target: style.id, dragging: $dragging, move: move))
            .help(style.enabled ? "Click to edit; drag to move." : "Off: the keys skip it. Click to edit.")
    }

    private func chipLabel(_ name: String, selected: Bool, on: Bool, fixed: Bool = false) -> some View {
        Text(name)
            .font(.callout.weight(selected ? .semibold : .regular))
            .strikethrough(!on)
            .foregroundStyle(selected ? Color.white : (on ? Color.primary : Color.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor
                                       : Color.secondary.opacity(fixed ? 0.08 : 0.18)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(fixed ? 0.35 : 0),
                                            style: StrokeStyle(lineWidth: 1, dash: [3])))
            .fixedSize()
    }

    /// Live reorder while dragging: the dragged chip takes the place of the one it's over.
    private func move(_ id: String, to target: String) {
        guard id != target, let from = styles.firstIndex(where: { $0.id == id }),
              let to = styles.firstIndex(where: { $0.id == target }) else { return }
        update { $0.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
    }

    @ViewBuilder private var addButton: some View {
        let missing = SuggestionStyle.builtIns.filter { b in !styles.contains { $0.id == b.id } }
        let add = {
            let style = SuggestionStyle(name: "New style", instructions: "")
            update { $0.append(style) }
            selected = style.id
        }
        if missing.isEmpty {
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("Add a style")
        } else {
            Menu {
                Button("New Style", action: add)
                Section("Restore") {
                    ForEach(missing) { b in Button(b.name) { update { $0.append(b) }; selected = b.id } }
                }
            } label: { Image(systemName: "plus") } primaryAction: { add() }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Add a style; hold for deleted built-ins")
        }
    }

    // MARK: Editor

    private func editor(_ style: SuggestionStyle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: Binding(get: { style.name }, set: { name in update(style.id) { $0.name = name } }))
                Toggle("On", isOn: Binding(get: { style.enabled }, set: { on in update(style.id) { $0.enabled = on } }))
                    .help("Off: the keys skip this style.")
            }
            TextEditor(text: Binding(get: { style.instructions },
                                     set: { text in update(style.id) { $0.instructions = text } }))
                .settingsTextBox(minHeight: 80)
                .settingsPlaceholder("How suggestions should sound in this style. Be strong and specific: a suggestion is only a few words.",
                                     shown: style.instructions.isEmpty)
            Picker("Length", selection: Binding(get: { style.length },
                                                set: { length in update(style.id) { $0.length = length } })) {
                Text("App\u{2019}s length").tag(LengthPreset?.none)
                ForEach(LengthPreset.allCases, id: \.self) { Text(GeneralPane.lengthName($0)).tag(Optional($0)) }
            }
            HStack {
                Spacer()
                if let original = SuggestionStyle.builtIn(id: style.id), style.isEditedBuiltIn {
                    Button("Reset to Default") {
                        update(style.id) { s in let on = s.enabled; s = original; s.enabled = on }
                    }
                }
                Button("Delete\u{2026}", role: .destructive) { confirmDelete = style }
                Button("Done") { selected = nil }
            }
        }
    }
}

private struct ChipDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        if let dragging { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
