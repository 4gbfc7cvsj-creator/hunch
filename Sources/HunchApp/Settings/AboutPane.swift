import SwiftUI

/// About: version and credits for the third-party data Hunch ships.
struct AboutPane: View {
    @State private var showingNotices = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                .searchAnchor("about.version")
            }
            Section("Acknowledgements") {
                Text("Hunch's list of common English words, which keeps everyday words from being learned, "
                     + "is built from these word lists:")
                credit("12dicts", "by Alan Beale, public domain. Frequency bands for everyday words.")
                credit("AGID", "by Kevin Atkinson. Plurals and verb forms (uses WordNet 1.6, Princeton University).")
                credit("SCOWL", "by Kevin Atkinson. Keeps only ordinary lowercase words.")
                LabeledContent("License notices") {
                    Button("Show…") { showingNotices = true }
                }
                .searchAnchor("about.licenses")
            }
        }
        .formStyle(.grouped)
        .searchScrollTarget("about")
        .sheet(isPresented: $showingNotices) { NoticesSheet() }
    }

    private func credit(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).fontWeight(.medium)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

/// The full THIRD-PARTY-NOTICES.md from the app bundle.
private struct NoticesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return "THIRD-PARTY-NOTICES.md is missing from this build."
        }
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 520)
    }
}
