import Foundation

/// Plain names for the technical names in macOS's sleep log (processes, wake reasons, wake requests), so the
/// "Sleep only" view reads without knowing macOS internals. The technical name stays available as a tooltip.
/// Unknown names are shown as they are (apps already have readable names, e.g. "Safari").
enum FriendlyNames {
    /// macOS's own background processes.
    private static let processes: [String: String] = [
        "cloudd": "iCloud sync", "bird": "iCloud Drive sync", "cloudtelemetryd": "iCloud diagnostics",
        "AddressBookSourceSync": "Contacts sync", "CalendarAgent": "Calendar sync",
        "coreaudiod": "Sound playing", "nsurlsessiond": "Background downloads",
        "runningboardd": "macOS app manager (for an app)", "mDNSResponder": "Network discovery (Bonjour)",
        "dasd": "macOS background tasks", "sharingd": "AirDrop, Handoff and sharing",
        "seld": "Apple Pay (secure chip)", "nfcd": "Apple Pay (NFC)", "financed": "Apple Wallet",
        "apsd": "Apple push notifications", "kernel_task": "macOS core (kernel)",
        "studentd": "Classroom (school management)", "backupd": "Time Machine backup",
        "backupd-helper": "Time Machine backup", "mds": "Spotlight indexing", "mds_stores": "Spotlight indexing",
        "mdsync": "Spotlight indexing", "mdworker": "Spotlight indexing", "mdworker_shared": "Spotlight indexing",
        "prl_vm_app": "Parallels Desktop (virtual machine)", "prl_client_app": "Parallels Desktop",
        "caffeinate": "Keep-awake command (from a script or an app)", "loginwindow": "Login window, screen lock",
        "ShipIt": "App update being installed", "useractivityd": "Handoff",
        "findmydeviced": "Find My", "searchpartyd": "Find My", "UniversalControl": "Universal Control",
        "PowerChime": "Charging sound", "bluetoothd": "Bluetooth", "ControlCenter": "Control Center",
        "helpd": "macOS Help", "PowerUIAgent": "Optimised battery charging", "powerd": "macOS power management",
        "WindowServer": "Display", "softwareupdated": "Software Update", "photoanalysisd": "Photos analysis",
        "mediaanalysisd": "Photos analysis", "airportd": "Wi-Fi", "wifid": "Wi-Fi", "locationd": "Location services",
        "timed": "Clock sync", "NotificationCenter": "Notifications (reminders, alarms)",
        "VoiceOver": "VoiceOver (screen reader)", "symptomsd": "Network diagnostics", "rapportd": "Nearby Apple devices",
    ]

    static func process(_ p: String) -> String { processes[p] ?? p }

    /// A sleep blocker, from its log label "process: what" or "process (type)": the process's plain name.
    static func blocker(_ label: String) -> String {
        if label == "macOS power management" { return label }
        let end = label.firstIndex(where: { $0 == ":" || $0 == "(" }) ?? label.endIndex
        return process(label[..<end].trimmingCharacters(in: .whitespaces))
    }

    /// A wake reason from macOS (e.g. "wifibt", "rtc Maintenance", "lid HID Activity").
    static func reason(_ r: String) -> String {
        let l = r.lowercased()
        if l.hasPrefix("aborted "), let n = l.split(separator: " ").dropFirst().first { return "Slept and woke again \(n)× in a row" }
        if l.contains("wifibt") && l.contains("hid") { return "Bluetooth keyboard, mouse or trackpad" }
        if l.contains("wifibt") && l.contains("useractivity") { return "Bluetooth device with user activity (keyboard, mouse, Apple Watch)" }
        if l.contains("wifibt") && l.contains("bluetooth") { return "Bluetooth" }
        if l.contains("wifibt") || l.contains("wlan") { return "Wi-Fi or Bluetooth (network, nearby devices)" }
        if l.contains("rtc") && l.contains("sleepservice") { return "Timer: Sleep Services (iCloud, Find My, mail)" }
        if l.contains("rtc") || l.contains("maintenance") { return "Timer: maintenance (Power Nap, backups, sync)" }
        if l.contains("lid") { return "Lid sensor" }
        if l.contains("trackpadkeyboard") || l.contains("keyboard") { return "Keyboard or trackpad" }
        if l.contains("hid activity") || l.contains("useractivity") { return "Activity signal (keyboard, trackpad, mouse)" }
        if l.contains("usb-c") || l.contains("charger") || l.contains("adapter") { return "Charger plugged in or out" }
        if l.contains("pwrbtn") || l.contains("power button") { return "Power button" }
        if l.contains("notification") { return "Notification" }
        return r
    }

    /// A planned wake, as "process (request)" from macOS's wake requests.
    static func requester(_ s: String) -> String {
        let known: [String: String] = [
            "powerd (UserWake)": "Wake at a set time (a schedule or an app's alarm)",
            "powerd (CSPNEvaluation)": "Power Nap check",
            "powerd (TCPKATurnOff)": "End of keeping network connections alive",
            "mDNSResponder (Maintenance)": "Network discovery: staying reachable for other devices",
            "dasd (TimerPlugin)": "Background task on a timer (backups, updates, sync)",
            "dasd (SleepService)": "Sleep Services (iCloud, Find My, mail)",
            "PowerUIAgent (Maintenance)": "Optimised battery charging",
            "NotificationCenter (Maintenance)": "Notifications (reminders, alarms)",
        ]
        if let k = known[s] { return k }
        let p = s.split(separator: " (", maxSplits: 1).first.map(String.init) ?? s
        return process(p)
    }
}

/// Tooltip texts in one layout: a plain explanation, optional bullet points, and macOS's own technical name in
/// the last line(s), each part separated by a blank line. Lines are not broken by hand: macOS wraps a tooltip at
/// its own width, and extra breaks would leave short leftover lines.
enum TipFormat {
    static func make(_ about: String, bullets: [String] = [], tech: [String] = []) -> String {
        var parts = [about]
        let list = bullets.map { "• " + $0 }.joined(separator: "\n")
        if !bullets.isEmpty { parts[0] += "\n" + list }     // the list follows its explanation directly
        if !tech.isEmpty { parts.append(tech.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
}

/// Plain explanations for the sleep view's tooltips (what a process, wake reason or setting does).
enum Explain {
    /// Apps on this Mac that contain the ShipIt updater (Squirrel, used by many Electron apps).
    static let shipItApps: [String] = {
        let fm = FileManager.default
        let dirs = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        return dirs.flatMap { d in (try? fm.contentsOfDirectory(atPath: d)) ?? [] }
            .filter { $0.hasSuffix(".app") }
            .filter { a in dirs.contains { fm.fileExists(atPath: "\($0)/\(a)/Contents/Frameworks/Squirrel.framework") } }
            .map { String($0.dropLast(4)) }.sorted()
    }()

    private static let processes: [String: (String, [String])] = [
        "ShipIt": ("Installs an app update that was downloaded in the background. It is the updater built into many apps made with Electron; macOS's log doesn't say for which app. If it keeps the Mac awake for hours, an update is stuck: open the app and update it by hand.", []),
        "caffeinate": ("A command that keeps the Mac awake, started by a script, a terminal or an app (e.g. during a long download or a build).", []),
        "powerd": ("macOS's own power management: after a wake-up it keeps the Mac awake for a short while to finish background work, e.g. Power Nap or network wake-ups.", []),
        "macOS power management": ("macOS's own power management: after a wake-up it keeps the Mac awake for a short while to finish background work, e.g. Power Nap or network wake-ups.", []),
        "backupd": ("Time Machine is making a backup.", []), "backupd-helper": ("Time Machine is making a backup.", []),
        "cloudd": ("iCloud syncing data (Photos, Drive, Notes and more).", []), "bird": ("iCloud Drive syncing files.", []),
        "nsurlsessiond": ("Downloads or uploads in the background for apps and macOS.", []),
        "coreaudiod": ("Sound is playing (or an app keeps the audio device open).", []),
        "mds": ("Spotlight is indexing files.", []), "mds_stores": ("Spotlight is indexing files.", []),
        "mdworker": ("Spotlight is indexing files.", []), "mdworker_shared": ("Spotlight is indexing files.", []),
        "softwareupdated": ("macOS Software Update is checking, downloading or installing.", []),
        "prl_vm_app": ("A Parallels Desktop virtual machine is running.", []),
        "dasd": ("macOS's scheduler for background work: it runs tasks such as backups, updates, sync and indexing when the Mac is idle or on power.", []),
        "WindowServer": ("The display server: something is shown on screen or an external display is connected.", []),
        "sharingd": ("AirDrop, Handoff and sharing with nearby devices.", []),
        "loginwindow": ("The login window and screen lock.", []),
        "runningboardd": ("macOS's app manager, keeping an app's background work running.", []),
        "mDNSResponder": ("Network discovery (Bonjour): keeps this Mac findable for other devices, e.g. for sharing and AirPlay.", []),
        "apsd": ("Apple push notifications: keeps the connection for notifications open.", []),
        "kernel_task": ("macOS's core (kernel), e.g. keeping the Mac cool or handling a device.", []),
        "mdsync": ("Spotlight is indexing files.", []),
        "financed": ("Apple Wallet updating card balances, transactions and orders in the background.", []),
        "seld": ("Apple Pay's secure chip doing background work (e.g. card updates).", []),
        "nfcd": ("Apple Pay's contactless (NFC) service.", []),
        "AddressBookSourceSync": ("Contacts syncing with your accounts (iCloud, Google, Exchange).", []),
        "CalendarAgent": ("Calendar syncing with your accounts.", []),
        "cloudtelemetryd": ("iCloud sending diagnostic data to Apple.", []),
        "studentd": ("Classroom: school device management.", []),
        "prl_client_app": ("The Parallels Desktop app (its virtual machines run separately).", []),
        "useractivityd": ("Handoff: passing what you do between your Apple devices.", []),
        "findmydeviced": ("Find My: keeps this Mac locatable.", []), "searchpartyd": ("Find My: keeps this Mac and your items locatable.", []),
        "UniversalControl": ("Universal Control: one keyboard and mouse across your Mac and iPad.", []),
        "PowerChime": ("The sound when the charger is plugged in.", []),
        "bluetoothd": ("Bluetooth: connected or nearby devices.", []),
        "ControlCenter": ("Control Center and the menu bar's status items.", []),
        "helpd": ("macOS Help (updating help content).", []),
        "PowerUIAgent": ("Optimised battery charging: decides when to finish charging.", []),
        "photoanalysisd": ("Photos analysing your library (faces, objects, memories).", []),
        "mediaanalysisd": ("Photos analysing pictures and videos (faces, objects, text).", []),
        "airportd": ("Wi-Fi.", []), "wifid": ("Wi-Fi.", []),
        "locationd": ("Location services.", []),
        "timed": ("Clock sync with Apple's time server.", []),
        "NotificationCenter": ("Notifications: a reminder, an alarm or a calendar alert.", []),
        "VoiceOver": ("VoiceOver, the screen reader.", []),
        "symptomsd": ("Network diagnostics (checks the connection's quality).", []),
        "rapportd": ("Communication with your nearby Apple devices (Handoff, AirDrop, Continuity).", []),
    ]

    /// A process (sleep blocker): explanation, and for ShipIt the installed apps that use it.
    static func process(_ p: String) -> String? {
        guard let e = processes[p] else { return nil }
        let apps = p == "ShipIt" && !shipItApps.isEmpty ? "\n\nApps on this Mac that use it: " + shipItApps.joined(separator: ", ") + "." : ""
        return TipFormat.make(e.0 + apps, bullets: e.1)
    }

    /// A wake reason from macOS.
    static func reason(_ r: String) -> (String, [String]) {
        let l = r.lowercased()
        if l.hasPrefix("aborted ") {
            return ("macOS started to sleep, aborted it at once and tried again, several times within seconds (counted as one wake-up). "
                    + "Something kept signalling activity, here the lid sensor or a keyboard/trackpad signal, e.g. with the lid open while the Mac went to idle sleep.", [])
        }
        let fully = " The Mac didn't wake fully (the display stayed off) and went back to sleep. Opening the lid and using the Mac ends the sleep: that isn't a wake-up during it and isn't counted here."
        let background = " The Mac didn't wake fully (the display stayed off) and went back to sleep."
        if l.contains("wifibt") && l.contains("hid") {
            return ("Input from a Bluetooth keyboard, mouse or trackpad woke the Mac in the background." + background, [])
        }
        if l.contains("wifibt") && l.contains("useractivity") {
            return ("A Bluetooth device signalled user activity and woke the Mac in the background, e.g. a keyboard or mouse, or an Apple Watch nearby." + background, [])
        }
        if l.contains("wifibt") && l.contains("bluetooth") {
            return ("The Bluetooth part of the Wi-Fi/Bluetooth chip woke the Mac: a paired device nearby (keyboard, mouse, headphones, Apple Watch).", [])
        }
        if l.contains("wifibt") || l.contains("wlan") {
            return ("The Wi-Fi and Bluetooth chip woke the Mac. macOS doesn't say which of the two:",
                    ["network activity: iCloud, Find My, other devices reaching this Mac",
                     "nearby devices: keyboard, mouse, headphones, Apple Watch unlock, Handoff, AirDrop"])
        }
        if l.contains("rtc") && l.contains("sleepservice") {
            return ("The Mac's built-in clock woke it for Sleep Services: short background work while asleep.",
                    ["iCloud and Find My", "mail and calendar", "notifications"])
        }
        if l.contains("rtc") || l.contains("maintenance") {
            return ("The Mac's built-in clock woke it for planned maintenance:",
                    ["Power Nap checks", "backups (e.g. Time Machine), updates and sync"])
        }
        if l.contains("lid") { return ("A signal from the lid sensor woke the Mac in the background." + fully, []) }
        if l.contains("usb-c") || l.contains("charger") || l.contains("adapter") { return ("The charger was plugged in or out.", []) }
        if l.contains("pwrbtn") || l.contains("power button") { return ("The power button was pressed.", []) }
        if l.contains("hid") || l.contains("keyboard") || l.contains("useractivity") {
            return ("A keyboard, trackpad or mouse signal woke the Mac in the background." + fully, [])
        }
        return ("macOS woke the Mac for this reason.", [])
    }

    /// A planned wake ("process (request)").
    static func requester(_ s: String) -> (String, [String]) {
        let known: [String: (String, [String])] = [
            "powerd (UserWake)": ("A wake-up at a set time: a schedule (System Settings, pmset) or an app's alarm or reminder.", []),
            "powerd (CSPNEvaluation)": ("A short Power Nap check: macOS decides whether there is background work to do.", []),
            "powerd (TCPKATurnOff)": ("Ends keeping network connections alive after a while asleep (saves power).", []),
            "mDNSResponder (Maintenance)": ("Network discovery (Bonjour) renews this Mac's network presence, so other devices still find it.", []),
            "dasd (TimerPlugin)": ("macOS's background scheduler starts planned work:", ["backups (e.g. Time Machine)", "app and system updates", "iCloud sync, Spotlight indexing"]),
            "dasd (SleepService)": ("Sleep Services: short background work while asleep.", ["iCloud and Find My", "mail and calendar"]),
            "PowerUIAgent (Maintenance)": ("Optimised battery charging checks when to finish charging.", []),
            "NotificationCenter (Maintenance)": ("A notification is due: a reminder, an alarm or a calendar alert.", []),
        ]
        return known[s] ?? ("An app or service asked macOS to wake the Mac at this time.", [])
    }

    /// macOS power settings named in the hints.
    static let settings: [String: String] = [
        "powernap": "Power Nap: while asleep, the Mac wakes now and then to check mail, sync iCloud, update Calendar and Notes and make Time Machine backups.",
        "SleepServices": "Sleep services: lets macOS do short background work while asleep, e.g. iCloud, Find My, mail and notifications.",
        "womp": "Wake for network access: the Mac wakes when another device wants something from it over the network, e.g. file or screen sharing, Music or Photos sharing, Find My.",
        "tcpkeepalive": "Keeps network connections open while asleep (iCloud, Find My, push notifications), so the Mac stays reachable. Costs a little power and causes wake-ups.",
    ]
    static func setting(_ key: String, _ state: String) -> String {
        TipFormat.make(settings[key] ?? key, tech: ["macOS setting: pmset \(key) = 1 \(state)"])
    }
}
