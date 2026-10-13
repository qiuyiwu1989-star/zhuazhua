import AppKit

MainActor.assumeIsolated {
    // Preserve local capture preferences when moving from the upstream bundle.
    if !UserDefaults.standard.bool(forKey: "captureMigrated") {
        for key in ["pegged", "inboxEnabled", "inboxOffered", "welcomed", "showOverFullScreen", "menuBarRevealOff", "quietHang", "lineSize", "keepOnLine", "soundOff", "extraFolders", "shortcut"] {
            if let value = CFPreferencesCopyAppValue(key as CFString, "app.tendedero.Tendedero" as CFString) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        UserDefaults.standard.set(true, forKey: "captureMigrated")
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
