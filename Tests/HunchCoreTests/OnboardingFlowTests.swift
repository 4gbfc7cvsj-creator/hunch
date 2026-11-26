import Testing
@testable import HunchCore

@Suite struct OnboardingFlowTests {
    typealias Step = OnboardingFlow.Step

    @Test func welcomeGoesToTheIntroVideoThenPermissions() {
        for granted in [false, true] {
            #expect(OnboardingFlow.next(from: .welcome, requiredGranted: granted) == .intro)
            #expect(OnboardingFlow.next(from: .intro, requiredGranted: granted) == .permissions)
        }
        #expect(OnboardingFlow.previous(from: .permissions) == .intro)
    }

    @Test func missingGrantsHoldThePermissionsStep() {
        #expect(OnboardingFlow.next(from: .permissions, requiredGranted: false) == .permissions)
        #expect(OnboardingFlow.next(from: .permissions, requiredGranted: true) == .loginItem)
    }

    @Test func setupLeadsIntoTheFeatureTourAndEndsAtDone() {
        for granted in [false, true] {
            #expect(OnboardingFlow.next(from: .loginItem, requiredGranted: granted) == .suggestions)
            #expect(OnboardingFlow.next(from: .suggestions, requiredGranted: granted) == .quickReplies)
            #expect(OnboardingFlow.next(from: .quickReplies, requiredGranted: granted) == .autocorrect)
            #expect(OnboardingFlow.next(from: .autocorrect, requiredGranted: granted) == .writeForMe)
            #expect(OnboardingFlow.next(from: .writeForMe, requiredGranted: granted) == .dictation)
            #expect(OnboardingFlow.next(from: .dictation, requiredGranted: granted) == .appearance)
            #expect(OnboardingFlow.next(from: .appearance, requiredGranted: granted) == .personalize)
            #expect(OnboardingFlow.next(from: .personalize, requiredGranted: granted) == .done)
            #expect(OnboardingFlow.next(from: .done, requiredGranted: granted) == .done)
        }
    }

    @Test func previousStepsBackOneAndStopsAtWelcome() {
        #expect(OnboardingFlow.previous(from: .welcome) == .welcome)
        for step in Step.allCases.dropFirst() {
            #expect(OnboardingFlow.previous(from: step).rawValue == step.rawValue - 1)
        }
    }

    @Test func partsSplitSetupFromFeatures() {
        #expect(OnboardingFlow.steps(in: .setup).allSatisfy { OnboardingFlow.part(of: $0) == .setup })
        #expect(OnboardingFlow.steps(in: .features).allSatisfy { OnboardingFlow.part(of: $0) == .features })
        #expect(OnboardingFlow.steps(in: .setup) + OnboardingFlow.steps(in: .features) + [.done] == Step.allCases)
    }

    @Test func skipJumpsFromAnyFeaturePageToDone() {
        for step in OnboardingFlow.steps(in: .features) {
            #expect(OnboardingFlow.skipFeatures(from: step) == .done)
        }
        for step in OnboardingFlow.steps(in: .setup) {
            #expect(OnboardingFlow.skipFeatures(from: step) == step)
        }
    }

    @Test func needsTourUnlessTheCurrentVersionWasFinished() {
        #expect(OnboardingFlow.needsTour(completedVersion: nil))
        #expect(OnboardingFlow.needsTour(completedVersion: 1))
        #expect(OnboardingFlow.needsTour(completedVersion: OnboardingFlow.currentVersion - 1))
        #expect(!OnboardingFlow.needsTour(completedVersion: OnboardingFlow.currentVersion))
        #expect(!OnboardingFlow.needsTour(completedVersion: OnboardingFlow.currentVersion + 1))
    }
}
