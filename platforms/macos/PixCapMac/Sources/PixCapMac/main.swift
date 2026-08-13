import Cocoa

// `--self-test` exercises the Rust bridge and the beautification pipeline
// without a UI session, so the render path can be verified from a terminal.
if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run() ? 0 : 1)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
