/// Step order of the first-run welcome tour. Pure, so the gating is testable without AppKit.
///
/// Two parts: setup (models, the intro video, permissions, login) and a skippable feature tour.
public enum OnboardingFlow {
    /// Bump when the tour gains a step every existing user should see; older completions reopen it.
    /// 2: models first, the feature tour (suggestions, autocorrect, Write for me, dictation, appearance,
    /// personalization).
    /// Not bumped for the intro video or the Autocorrect and Quick replies pages: they are for new users,
    /// and Settings → General reopens the tour.
    public static let currentVersion = 2

    public enum Step: Int, CaseIterable, Sendable {
        case welcome
        /// The intro video, right after the models are picked (it plays while they start downloading).
        case intro
        case permissions, loginItem
        case suggestions, quickReplies, autocorrect, writeForMe, dictation, appearance, personalize
        case done
    }

    public enum Part: Sendable { case setup, features }

    public static func part(of step: Step) -> Part {
        step.rawValue <= Step.loginItem.rawValue ? .setup : .features
    }

    /// The steps of a part, in order (`done` belongs to neither).
    public static func steps(in part: Part) -> [Step] {
        switch part {
        case .setup: [.welcome, .intro, .permissions, .loginItem]
        case .features: [.suggestions, .quickReplies, .autocorrect, .writeForMe, .dictation, .appearance, .personalize]
        }
    }

    /// The step after `step`. Permissions hold the tour until Accessibility and Input Monitoring
    /// are both granted (nothing works without them). `done` is the last step.
    public static func next(from step: Step, requiredGranted: Bool) -> Step {
        if step == .permissions, !requiredGranted { return .permissions }
        return Step(rawValue: step.rawValue + 1) ?? .done
    }

    /// The step before `step`, in plain order.
    public static func previous(from step: Step) -> Step {
        Step(rawValue: step.rawValue - 1) ?? .welcome
    }

    /// "Skip" on a feature page jumps to the end.
    public static func skipFeatures(from step: Step) -> Step {
        part(of: step) == .features ? .done : step
    }

    /// True when the tour was never finished, or finished in an older version of it.
    public static func needsTour(completedVersion: Int?) -> Bool {
        guard let completedVersion else { return true }
        return completedVersion < currentVersion
    }
}
