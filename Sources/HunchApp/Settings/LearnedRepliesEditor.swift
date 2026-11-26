import HunchCore
import HunchHistory
import SwiftUI

/// "Learned replies" in Learned data: the questions that keep coming back in an app, and the
/// answers the user sends to them. Pick a question to edit or delete its answers, add answers,
/// block it (nothing learned or offered for it again) or delete it; or add a question by hand.
struct LearnedRepliesEditor: View {
    let learning: LearningPaneModel
    let repliesOn: Bool
    @State private var selection: LearnedQuestion.ID?
    @State private var newAnswer = ""
    @State private var editing: (question: String, answer: String)?
    @State private var editText = ""
    @State private var adding = false

    private var selected: LearnedQuestion? { learning.replyQuestions.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(learning.replyQuestions, selection: $selection) {
                TableColumn("Question") { q in Text(q.keys.last ?? "").lineLimit(1).help(q.keys.joined(separator: "\n")) }
                TableColumn("App") { q in Text(AppKeyName.display(q.appKey)) }.width(110)
                TableColumn("Answers") { q in Text(Self.summary(q)).lineLimit(1) }.width(190)
                TableColumn("Last seen") { q in
                    if q.blocked { Text("Blocked").foregroundStyle(.secondary) } else {
                        Text(q.lastSeen, format: .relative(presentation: .named))
                    }
                }.width(100)
            }
            .frame(height: 180)
            if let q = selected {
                answers(q)
            } else if learning.replyQuestions.isEmpty {
                Text("Questions appear here after you answer one by picking a quick reply (on its own, or with your own words after it). Only the newest message of theirs is matched, never older ones further up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Add a Question\u{2026}") { adding = true }
                Spacer()
            }
            if let error = learning.editError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Only replies you pick are learned, with any words you add after them; messages you type yourself are not. When the same question comes back in an app (similar wording, or the same quoted options), your usual answers go first in the reply bubble, and the start your answers share is offered too (\u{201C}Done testing, \u{201D}). After 3 or more answers, when they cover most of what you send, they show at once without asking the model. Answers you haven't sent for 60 days drop out, and questions unseen for 90 days are forgotten; ones you add or edit stay. Learned while Quick replies and \u{201C}Learn words and phrases\u{201D} are both on."
                 + (repliesOn ? "" : " Quick replies are off, so nothing is learned or offered now."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit answer").font(.headline)
                TextField("Answer", text: $editText).textFieldStyle(.roundedBorder).frame(width: 360)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        guard let e = editing else { return }
                        let text = editText
                        editing = nil
                        apply { try $0.renameAnswer(questionID: e.question, from: e.answer, to: text) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $adding) {
            AddLearnedQuestionSheet(learning: learning) { adding = false }
        }
    }

    private func answers(_ q: LearnedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(q.answers.sorted { $0.sends != $1.sends ? $0.sends > $1.sends : $0.lastSent > $1.lastSent },
                    id: \.text) { a in
                HStack(spacing: 8) {
                    Text(a.text).lineLimit(1)
                    Text(a.manual ? "added" : "sent \(a.sends)\u{00D7}").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit") { editing = (q.id, a.text); editText = a.text }
                    Button(role: .destructive) {
                        apply { try $0.deleteAnswer(questionID: q.id, text: a.text) }
                    } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
            }
            HStack {
                TextField("Add an answer", text: $newAnswer).textFieldStyle(.roundedBorder).onSubmit { addAnswer(q) }
                Button("Add") { addAnswer(q) }.disabled(newAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(q.blocked ? "Unblock" : "Block") {
                    let id = q.id, block = !q.blocked
                    apply { try $0.setBlocked(id: id, block) }
                }
                .help("A blocked question gets no learned replies, and nothing is learned from it.")
                Button("Delete Question", role: .destructive) {
                    let id = q.id
                    selection = nil
                    apply { try $0.deleteQuestion(id: id) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func addAnswer(_ q: LearnedQuestion) {
        let text = newAnswer, id = q.id, app = q.appKey
        Task {
            await learning.perform {
                try await learning.editReplies? { try $0.addManual(question: nil, questionID: id, answers: [text], appKey: app) }
            }
            if learning.editError == nil { newAnswer = "" }
        }
    }

    private func apply(_ edit: @escaping @Sendable (inout LearnedReplies) throws -> Void) {
        Task { await learning.perform { try await learning.editReplies?(edit) } }
    }

    /// "Done testing ×3, Skip testing ×1".
    static func summary(_ q: LearnedQuestion) -> String {
        q.answers.sorted { $0.sends > $1.sends }.map { $0.manual && $0.sends == 0 ? $0.text : "\($0.text) \u{00D7}\($0.sends)" }
            .joined(separator: ", ")
    }
}

/// Adds a question by hand: the app it's asked in, its words as they appear on screen, and answers.
private struct AddLearnedQuestionSheet: View {
    let learning: LearningPaneModel
    let done: () -> Void
    @State private var app = ""
    @State private var otherApp = ""
    @State private var question = ""
    @State private var answers = ""

    /// Apps and sites Hunch has learned from, most used first.
    private var places: [String] {
        var seen: [String] = []
        for k in learning.replyQuestions.map(\.appKey) + learning.snippets.compactMap({ $0.appKey ?? $0.appBundleID })
        where !seen.contains(k) { seen.append(k) }
        return seen
    }

    private var appKey: String {
        let typed = otherApp.trimmingCharacters(in: .whitespaces)
        return app.isEmpty ? typed : app
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a question").font(.headline)
            Picker("App or site", selection: $app) {
                ForEach(places, id: \.self) { Text(AppKeyName.display($0)).tag($0) }
                Text("Other\u{2026}").tag("")
            }
            if app.isEmpty {
                TextField("Bundle ID or website (com.apple.MobileSMS, claude.ai)", text: $otherApp)
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Their question, as it appears on screen", text: $question, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            TextField("Your answers, one per line", text: $answers, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
            if let error = learning.editError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add") {
                    let key = appKey, q = question
                    let list = answers.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    Task {
                        await learning.perform {
                            try await learning.editReplies? { try $0.addManual(question: q, answers: list, appKey: key) }
                        }
                        if learning.editError == nil { done() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appKey.isEmpty || question.trimmingCharacters(in: .whitespaces).isEmpty
                          || answers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { app = places.first ?? "" }
    }
}
