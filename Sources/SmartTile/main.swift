import AppKit

// SmartTile — tiles windows automatically based on the apps you are using,
// and learns window placement from your habits.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
