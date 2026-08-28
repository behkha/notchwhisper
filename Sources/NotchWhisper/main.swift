import AppKit

// Entry point for a standard macOS app. The main thread is the MainActor, so
// we construct the @MainActor delegate here and let AppKit drive the lifecycle.
let app = NSApplication.shared

// `NotchWhisper --type-test "some text"` types the text into the frontmost app
// via the normal AutoTyper path and exits — an end-to-end test of dictation
// insertion with no UI and no microphone needed.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--type-test"),
   CommandLine.arguments.count > flagIdx + 1 {
    let text = CommandLine.arguments[flagIdx + 1]
    // Optional --delay N (seconds) to let the target app get focus first.
    var delay: Double = 0
    if let dIdx = CommandLine.arguments.firstIndex(of: "--delay"),
       CommandLine.arguments.count > dIdx + 1, let d = Double(CommandLine.arguments[dIdx + 1]) {
        delay = d
    }
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    MainActor.assumeIsolated {
        AutoTyper.type(text)
    }
    exit(0)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
}
app.run()
