import Foundation
import Testing
@testable import RemoteDesk

@Test func relaunchWaitsForThePreviousProcessToExit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "Infinite Remote Relaunch \(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appending(path: "test executable")
    let marker = directory.appending(path: "launched")
    try "#!/bin/sh\n/usr/bin/touch \"${0%/*}/launched\"\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let previous = Process()
    previous.executableURL = URL(fileURLWithPath: "/bin/sleep")
    previous.arguments = ["15"]
    try previous.run()
    defer { if previous.isRunning { previous.terminate() } }

    try AppRelaunch.schedule(after: previous.processIdentifier, bundleURL: directory, executableURL: executable)
    try await Task.sleep(for: .milliseconds(300))
    #expect(previous.isRunning)
    #expect(!FileManager.default.fileExists(atPath: marker.path))

    previous.terminate()
    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
}
