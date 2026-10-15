// main.swift — the executable's entry point. Top-level code is only allowed in
// a file literally named main.swift, which both `swiftc` (build.sh) and the
// Xcode project compile happily.
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar app, no Dock icon
app.run()
