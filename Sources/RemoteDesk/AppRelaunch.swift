import Foundation

enum AppRelaunch {
    static func schedule(after pid: Int32, bundleURL: URL, executableURL: URL?) throws {
        let isAppBundle = bundleURL.pathExtension == "app"
        guard let target = isAppBundle ? bundleURL : executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for normal AppKit termination, including release of the debug instance lock.
        // The limit keeps the helper from waiting indefinitely if the app cannot quit.
        helper.arguments = ["-c", """
            attempts=0
            while kill -0 "$1" 2>/dev/null; do
                [ "$attempts" -lt 600 ] || exit 1
                attempts=$((attempts + 1))
                /bin/sleep 0.1
            done
            if [ "$2" = app ]; then
                exec /usr/bin/open "$3"
            fi
            exec "$3"
            """, "relaunch", String(pid), isAppBundle ? "app" : "executable", target.path]
        try helper.run()
    }
}
