import AppKit
import Testing
@testable import RemoteDesk

@Test
func onlyFocusChangesFromUserInputEventsCountAsUserIntent() {
    #expect(Workspace.focusWasAssignedAutomatically(currentEventType: nil))
    #expect(Workspace.focusWasAssignedAutomatically(currentEventType: .appKitDefined))
    #expect(Workspace.focusWasAssignedAutomatically(currentEventType: .systemDefined))
    #expect(Workspace.focusWasAssignedAutomatically(currentEventType: .applicationDefined))
    #expect(Workspace.focusWasAssignedAutomatically(currentEventType: .periodic))
}

@Test
func keyboardAndPointerEventsKeepTheirFocus() {
    let userInputEvents: [NSEvent.EventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .scrollWheel
    ]
    for event in userInputEvents {
        #expect(!Workspace.focusWasAssignedAutomatically(currentEventType: event), "\(event) keeps focus")
    }
}
