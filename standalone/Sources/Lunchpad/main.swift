import AppKit

// A command-line executable starts on the main thread; declare isolation explicitly for Swift 6.
MainActor.assumeIsolated {
    // Start NSApplication manually so launching the app can show its window immediately.
    let appDelegate = AppDelegate()
    let application = NSApplication.shared
    application.delegate = appDelegate
    application.setActivationPolicy(.regular)
    application.run()
}
