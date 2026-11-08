import Testing
@testable import RemoteDesk

@MainActor
final class CodexConversationFixture: CodexConversationSession {
    var observation: CodexDraftObservation? = .empty
    var reads = 0
    var sent: [String] = []
    var acceptsSend = true

    func observe() -> CodexDraftObservation? {
        reads += 1
        return observation
    }

    func send(_ transcript: String) -> Bool {
        sent.append(transcript)
        return acceptsSend
    }
}

@Test @MainActor
func codexConfirmationWaitsForThisRecordingAndOnlySendsOnExplicitConfirmation() {
    let session = CodexConversationFixture()
    let controller = CodexDraftConfirmation()
    #expect(controller.begin(session))
    session.observation = .starting
    controller.sample()
    session.observation = .recording
    controller.sample()
    controller.release()
    session.observation = .transcribing
    #expect(controller.confirm() == .unavailable)
    session.observation = .ready("Read the latest reply")
    controller.sample()
    #expect(session.sent.isEmpty)
    #expect(controller.confirm() == .requested)
    #expect(controller.confirm() == .unavailable)
    #expect(session.sent == ["Read the latest reply"])
}

@Test @MainActor
func codexConfirmationRejectsExistingDraftsAndUnobservedTranscription() {
    let session = CodexConversationFixture()
    let controller = CodexDraftConfirmation()
    session.observation = .ready("Existing draft")
    #expect(!controller.begin(session))
    #expect(controller.confirm() == .unavailable)
    session.observation = .empty
    #expect(controller.begin(session))
    session.observation = .recording
    controller.sample()
    controller.release()
    session.observation = .ready("Edited text without a transcription transition")
    #expect(controller.confirm() == .unavailable)
    #expect(session.sent.isEmpty)
}

@Test(arguments: ["approval or changed conversation", "edited draft", "timed out sending"])
@MainActor
func codexConfirmationInvalidatesOrConsumesTheArmedDraft(_ scenario: String) {
    let session = CodexConversationFixture()
    let controller = CodexDraftConfirmation()
    #expect(controller.begin(session))
    session.observation = .recording
    controller.sample()
    session.observation = .transcribing
    controller.release()
    session.observation = .ready("Draft")
    controller.sample()
    if scenario == "timed out sending" {
        session.acceptsSend = false
        #expect(controller.confirm() == .unconfirmed)
        #expect(session.sent == ["Draft"])
    } else {
        session.observation = scenario == "edited draft" ? .ready("Changed") : nil
        controller.sample()
        #expect(session.sent.isEmpty)
    }
    session.observation = .ready("Draft")
    #expect(controller.confirm() == .unavailable)
    #expect(session.sent.count == (scenario == "timed out sending" ? 1 : 0))
}
