import Foundation

/// Human-facing copy for every test, kept in one place.
///
/// Tests measure; this file explains. Splitting them means the wording — which
/// is what testers actually give feedback on — can be reviewed and rewritten
/// without touching a single measurement, and without hunting through six
/// files to find where a sentence lives.
///
/// Written for someone who is not an engineer. The first external tester's
/// feedback was entirely about this: sensors failed because nobody said to put
/// the phone down, cameras failed because nobody said to uncover the lenses,
/// and "Memory" was read as storage.
enum TestGuidance {
    struct Entry {
        /// What the test checks, in a sentence or two.
        let about: String
        /// What to do first so the setup does not cause a false failure. Nil
        /// when there is genuinely nothing to prepare.
        let preparation: String?
        /// Why it is left out of Run All. Required for exactly the tests
        /// marked `requiresInteraction` — `enrich` asserts it — so the
        /// sentence can never describe behaviour the code does not have.
        var runsAlone: String? = nil
    }

    /// Identical preparation text is grouped in the Run All checklist, so tests
    /// that need the same setup share one string rather than two near-copies.
    private static let layItFlat =
        "Lay the device flat on a table and don't touch it until the test ends. "
        + "Holding it — even steadily — adds movement that reads as a faulty sensor."

    static let entries: [String: Entry] = [
        // Sensors
        "motion.accelerometer": Entry(
            about: "Measures gravity with the device at rest. A healthy sensor reads "
                + "almost exactly 1 g, with very little noise.",
            preparation: layItFlat),
        "motion.gyroscope": Entry(
            about: "Measures rotation. At rest it should read almost zero — a steady "
                + "reading is drift, which makes rotation and motion features wander.",
            preparation: layItFlat),
        "motion.magnetometer": Entry(
            about: "The compass. Once iOS has calibrated it, it should see Earth's "
                + "magnetic field — about 25–65 µT.",
            preparation: "Keep it clear of magnets: MagSafe cases and wallets, stands, "
                + "laptops, speakers. If it reports uncalibrated, move the device in a "
                + "figure-eight a few times, then run it again."),
        "motion.barometer": Entry(
            about: "Measures air pressure, which the device uses for altitude and "
                + "counting floors climbed. Near sea level it reads about 100 kPa.",
            preparation: nil),
        "biometrics.info": Entry(
            about: "Checks Face ID or Touch ID is present and set up. It does not scan "
                + "your face or fingerprint.",
            preparation: nil),

        // Display
        "display.info": Entry(
            about: "Reports the screen's resolution and refresh rate, and checks the "
                + "display is running at the rate the hardware supports.",
            preparation: nil),
        "display.sweep": Entry(
            about: "Fills the screen with solid colours one at a time so you can look "
                + "for dead or stuck pixels, discolouration, or light bleeding at the edges.",
            preparation: "Turn brightness up and look straight at the screen.",
            runsAlone: "It needs you to look at each colour and say what you see, "
                + "so it runs on its own rather than as part of Run All."),
        "display.touch": Entry(
            about: "Shows a grid to trace over with one finger. Any square that doesn't "
                + "register is a dead zone in the touchscreen.",
            preparation: nil,
            runsAlone: "It needs you to trace the grid with a finger, so it runs on its "
                + "own rather than as part of Run All."),

        // Compute
        "compute.cpu": Entry(
            about: "Runs a fixed workload on one core, then on all of them. Checks every "
                + "core works and that they add up the way they should.",
            preparation: nil),
        "compute.gpu": Entry(
            about: "Runs a calculation on the graphics chip and checks the answer is "
                + "correct — not just that it finished.",
            preparation: nil),
        "memory.info": Entry(
            about: "Reports how much RAM the device has. RAM is working memory — what "
                + "apps use while they're open — and is normally 4–12 GB. It is not "
                + "storage: your photos and apps live in storage, which is far larger. "
                + "To test the RAM itself under load, run RAM Under Pressure.",
            preparation: nil),
        "memory.pressure": Entry(
            about: "Fills most of the memory an app is allowed with test data, which forces "
                + "iOS to squeeze everything else — and close other apps if it has to — then "
                + "reads it all back to check every byte survived. Shows how much memory an app can really get, when the "
                + "device starts to struggle, and whether the RAM holds data correctly under load.",
            preparation: "Save anything open in other apps first — iOS may close them to make "
                + "room, and they'd reopen from scratch. Stay in this app until it finishes.",
            runsAlone: "It asks before it starts and is excluded from Run All, since on a "
                + "device with less memory headroom iOS may close other apps to make room."),

        // Thermal, storage, power
        "thermal.sustained": Entry(
            about: "Works every core flat out for about 14 seconds, then compares the "
                + "last two seconds with the fastest second of the run. A device that can't "
                + "shed heat slows itself down to stay safe, and that shows up here.",
            preparation: "Unplug the charger first — charging adds heat of its own and "
                + "can make healthy cooling look poor."),
        "storage.throughput": Entry(
            about: "Writes and reads a temporary file to measure how fast the built-in "
                + "storage is. The file is deleted afterwards.",
            preparation: nil),
        "battery.health": Entry(
            about: "Judges your battery's health from the figures in Settings — Maximum "
                + "Capacity and, where Settings shows it, Cycle Count — against what Apple "
                + "designs the battery in your model to reach, and explains what they mean.",
            preparation: nil,
            runsAlone: "iOS doesn't let apps read battery health, so it needs you to read two "
                + "figures from Settings and type them in. It runs on its own rather than as "
                + "part of Run All."),
        "power.context": Entry(
            about: "Records the conditions that affect battery readings — brightness, "
                + "charging, Low Power Mode and temperature — so other results can be "
                + "read in context.",
            preparation: nil),

        // Cameras, audio, radios
        "camera.capture": Entry(
            about: "Opens every camera on the device, front and rear, and checks each "
                + "one returns a real image rather than a black frame.",
            preparation: "Uncover every lens — take it out of any case that blocks one — "
                + "and run it somewhere lit. A lens facing a table or a dark room returns "
                + "a black frame, which counts as a failure."),
        "audio.loopback": Entry(
            about: "Plays a tone through the speaker and listens for it on the "
                + "microphone. Hearing it proves both work.",
            preparation: "Turn the volume up to at least half and run it somewhere fairly "
                + "quiet. Don't cover the speaker or the microphones."),
        "radio.bluetooth": Entry(
            about: "Listens for nearby Bluetooth devices for a few seconds. Hearing any "
                + "at all proves the radio can receive.",
            preparation: nil),
        "radio.location": Entry(
            about: "Asks the satellite receiver for a location fix and times how long "
                + "it takes.",
            preparation: "Run it outdoors or next to a window. Indoors the receiver often "
                + "can't see enough satellites within 30 seconds — that's the building, "
                + "not a fault."),
    ]

    /// Fold the copy into a descriptor. Tests never set these themselves.
    static func enrich(_ d: AgentTestDescriptor) -> AgentTestDescriptor {
        guard let entry = entries[d.id] else { return d }
        // Left out of Run All ⇔ requiresInteraction, so the two must agree:
        // a test that runs alone without saying why leaves people guessing,
        // and a reason on a test Run All does include would be false.
        assert((entry.runsAlone != nil) == d.requiresInteraction,
               "\(d.id): runsAlone must be set for exactly the tests Run All leaves out")
        var out = d
        out.about = entry.about
        out.preparation = entry.preparation
        out.runsAlone = entry.runsAlone
        return out
    }
}
