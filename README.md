# Auscult

Full system and hardware diagnostics for iOS devices, from a Mac — on any OS
build, shipping or seed.

Verified working against **iPhone 17 Pro Max on iOS 27.0 (24A5418b)**, a
prerelease build, on macOS 27.0 with Xcode 26.5.

```
POWER & BATTERY
  ✓ Battery — 91.2% of original capacity, 553 cycles
      ✓ Battery health: 91.21%       (nominal charge capacity vs design)
        Design capacity: 4,768 mAh
        Nominal charge capacity: 4,349 mAh
      ✓ Cycle count: 553 cycles
        Battery serial: ••••••••••••••X7Q2
      ✓ Cell voltage: 3.93 V
      ✓ Cell temperature: 29 °C
      ✓ Unexpected power-off reboots: 0
        Adapter power: 15 W          (pd charger)
```

## Why beta builds don't break it

Third-party iOS tooling breaks every September because it hard-codes what the
OS looks like. Auscult is built the other way round:

1. **Apple's own stack is the primary transport.** `devicectl` ships inside
   Xcode and Apple updates it in lockstep with every build, including internal
   trains. Whatever pairing or tunnel scheme a seed introduces, that binary
   already speaks it.
2. **No version checks anywhere.** Not one line branches on an iOS version.
   Transports *probe* what they can actually do against the device in front of
   them and advertise [capabilities](Sources/AuscultKit/Model/Capability.swift);
   probes declare what they need. A seed that moves a service costs one
   capability, not the app.
3. **Every field is read through a candidate list, newest first.** Apple has
   already deprecated `hardwareProperties` in favour of `properties`; reading
   both means neither the removal of the old nor another reshuffle of the new
   costs a reading. See [`DynamicValue`](Sources/AuscultKit/Transport/DynamicValue.swift).
4. **Subsystems, not process names.** `mediaserverd` no longer exists on iOS 27
   — it became `mediaplaybackd` and `audiomxd`. Checking "is *some* media daemon
   alive" survives that; checking for a name reports healthy hardware as dead.
5. **Unexpected failures are loud.** A probe that throws is reported as `error`,
   distinct from `unsupported`. That distinction is the early-warning system for
   "a new build moved something".

## Architecture

```
DiagnosticSession
├── TransportRouter          picks who answers what, caches, falls back
│   ├── CoreDeviceTransport  devicectl · breadth + beta immunity
│   ├── LockdownTransport    usbmux → lockdownd → diagnostics relay · depth
│   └── CfgutilTransport     Apple Configurator · IMEI, disk usage, MACs
└── ProbeEngine              runs probes, assembles the report
```

Probes never know which transport served them. They ask for a
`TransportRequest`; the router finds a transport that has advertised the
matching capability, and if it fails at request time — exactly what an OS seed
looks like — demotes it and tries the next.

### The deep path

`CoreDevice` deliberately exposes no battery gas gauge and no NAND wear. Those
come from a native Swift implementation of the classic stack:

```
usbmuxd (unix socket, plist framing)   ← pair records without root
   └── lockdownd :62078
         ├── QueryType / StartSession
         ├── mutual TLS on the same socket   ← SecIdentity from the pair record
         └── StartService
               └── com.apple.mobile.diagnostics_relay
                     └── IORegistry · MobileGestalt · GasGauge
```

Two parts of this were the hard bits, and both are documented in the source:

- **[`HostIdentity`](Sources/AuscultKit/Services/HostIdentity.swift)** — there is
  no public API to build a `SecIdentity` from a loose cert/key pair, so we create
  a throwaway keychain in a temp directory, import the pair record's credentials,
  take the identity, and delete the keychain. Nothing touches the login keychain.
- **[`BlockingIO`](Sources/AuscultKit/Services/BlockingIO.swift)** — Secure
  Transport's IO callbacks are blocking C functions. Calling them from an `async`
  context parks a cooperative thread inside a syscall; with several transports
  probing concurrently that exhausts the pool and deadlocks the process. Every
  blocking chain is dispatched to a real thread and awaited through a
  continuation.

## Usage

```bash
swift build -c release
./Scripts/bundle-app.sh release      # builds build/Auscult.app
```

```bash
auscult doctor                 # which data paths this host has
auscult list                   # every visible device
auscult run                    # diagnose the first connected device
auscult run <udid> --json      # machine-readable report
auscult run <udid> --csv       # one row per metric, for diffing two runs
```

Low-level triage, for when something stops working after an OS update:

```bash
auscult usbmux                 # mux layer + pair record state
auscult relay <udid>           # trace the deep handshake step by step
auscult ioreg --name AppleSmartBattery   # dump any IORegistry node
auscult pairtest <file>        # verify a pair record builds a TLS identity
```

`auscult relay` walks the five distinct failure points (mux, pair record, TLS
identity, session, service) one at a time. From the outside they produce nearly
identical symptoms; this is the difference between a five-second diagnosis and
guessing.

## What it measures today

| Section | Source | Notes |
|---|---|---|
| Identity | CoreDevice | model, board, chip, cores, biometrics, ECID, serial |
| Software | CoreDevice | version, build, train, **seed detection** |
| Integrity | CoreDevice | production fuse, sealed system volume, Developer Mode |
| Battery | diagnostics relay | health, cycles, capacities, cell serial, voltage, temp, unexpected power-offs, adapter |
| Storage | cfgutil | capacity, free-space grading, per-category usage |
| Display | CoreDevice | geometry, scale, refresh, HDR |
| Radios | cfgutil | IMEI ×2, ICCID ×2, baseband, Wi-Fi/BT MACs, activation |
| Subsystems | CoreDevice | liveness of 12 subsystems, by daemon group |
| Apps | CoreDevice | inventory, developer-signed apps |

### Deliberately not claimed

The host can only read what iOS chooses to report. Dead pixels, touch
digitizer coverage, per-lens camera capture, speaker/mic loopback, gyro bias,
GNSS time-to-fix, and haptics **cannot** be tested from a Mac. Auscult reports
those as "requires the on-device agent" rather than silently omitting them — the
report tells you what wasn't measured, not just what was.

Also worth knowing: on iOS 27 the relay's `NAND` request returns
`NANDInfoDeprecated`. Apple removed it. Auscult reports that honestly instead
of inventing a wear figure.

## The on-device agent

Some hardware simply cannot be tested from a Mac — there is no API that reports
a stuck subpixel, and the host cannot spin a gyroscope. So `Agent/` is a signed
iOS app that runs those tests on the device and reports back.

The host reaches it over the **cable**: the agent opens a TCP listener on the
device's loopback interface and usbmuxd tunnels a Mac-side socket to it. No
Bonjour, no Wi-Fi, no Local Network permission prompt, and no pairing beyond the
one the Mac already has. Because usbmux port forwarding is not something OS
seeds change, this works the same on any iOS version.

The **agent owns the catalogue**. The host asks what tests exist and synthesises
one probe per entry, so adding a test to the agent requires no host change at
all.

```bash
Scripts/build-agent.sh              # build, sign, install
auscult agent                        # list what the device can test
auscult agent --test compute.gpu     # run one test
auscult run <udid> --guided          # everything, including the guided checks
```

Measured on an iPhone 17 Pro Max, iOS 27.0 seed:

| Test | Result |
|---|---|
| Accelerometer | 1.00 g at rest, noise 0.0012 g, all axes live |
| Gyroscope | zero-rate bias 0.0061 rad/s |
| Magnetometer | raw field, calibration quality, Earth-field check |
| CPU | 176 M iter/s single, 617 M multi, **6.1× scaling on 6 cores** |
| GPU | Apple A19 Pro, **282 GFLOPS**, output verified not just dispatched |
| Thermal | 14 s all-core load, throughput retained, throttle curve |
| Storage | write 1.5 GB/s, read 2.6 GB/s — cache-bypassed, byte-verified |
| Display | 1320×2868 at 120 Hz, EDR headroom 8× |
| Biometrics | Face ID present and enrolled |
| Display sweep | guided — 5 colour fields, **5/5 clean** |
| Touch digitizer | guided — **40/40 cells**, faults localised by cell |
| Cameras | all 6 lenses enumerated, per-lens frame statistics |
| Speaker & mics | **tone recovered at 63 dB**, 3 microphones enumerated |
| Bluetooth | **54 advertisers heard**, strongest −29 dBm |
| GNSS | time-to-first-fix and accuracy (coordinates withheld) |

### Standalone mode

The agent runs its whole catalogue with no Mac attached. That is the default
tab; the host link is the secondary one.

This matters beyond convenience. The agent shipped to TestFlight initially could
not run a single check on its own — it opened on a "waiting for the Mac" screen,
which makes it untestable by anyone who is not sitting at this particular Mac
with a cable. A beta build nobody can exercise is not a beta build.

The tests never needed a host. `AgentTest.run(context:)` takes three closures
and nothing else. What needed a host was the code that *drove* them, which lived
inside `AgentServer` next to the socket. `DiagnosticRunner` now owns that —
the detached-task hop that keeps the compute tests off the main actor and away
from the watchdog, the idle-timer window, the prompt continuations, the result
store — and the host path goes through it too, via `on…` hooks that are nil when
running standalone. One implementation, not two that drift.

`Run All` covers everything that works unattended. Interactive tests are
excluded from it on purpose: each blocks on a person and gives up after 45s, so
sweeping them would produce minutes of timeouts reported as failures. They stay
individually runnable and are marked "needs you".

## Investigating battery drain

`auscult drain` is the purpose-built workflow, because the ordinary probe reports
whatever the device happens to be doing and that is nearly useless for the
question:

```bash
auscult drain --wait 20 --seconds 60    # lock the screen during the countdown
```

It reads `AppleARMBacklight`'s `CurrentNits` so it knows whether the panel was
actually dark, and **grades against different thresholds accordingly** — 3 W is
unremarkable with the screen lit and a significant finding with it off. Without
that check the measurement rests on the operator's word.

The report also derives the PMU's accumulators: mean draw during the periods the
device was on battery, mean system load since boot, charger conversion loss, and
a projected runtime from pack energy divided by measured draw.

### Paired accessories come along for free

An Apple Watch cannot be diagnosed over a cable, and the reason is worth
stating because the hardware invites the opposite conclusion. Plug a Watch into
a Mac and `ioreg` shows:

```
USB Vendor Name  = "Apple Inc."
USB Product Name = "Apple Watch Magnetic Charging Cable"
```

The Mac sees *the cable* — which enumerates as a USB device in its own right —
and nothing behind it. The charger is an induction coil with no data lines, so
no configuration can turn it into a link. `auscult pair` detects attached
power-only accessories and says so, rather than leaving someone to conclude
their Watch is broken or unsupported.


What works instead: a Watch pairs to a phone and forwards
its crash and resource reports through it. Those land in the phone's crash-log
directory under `ProxiedDevice-<id>/`, so a useful slice of Watch health is
reachable without the Watch being paired to Xcode at all.

This was originally a *bug*: the index attributed those reports to the phone, so
a watch app crashing 131 times appeared in the iPhone's offender ranking.
Reports now carry an `Origin`, rankings are host-only by default, and
`AccessoryHealthProbe` reports accessories separately.

What an accessory gives is crash and resource history — enough to identify an
app misbehaving on the wrist. What it does not give is a battery gauge,
IORegistry, or an agent, because none of those reach through the proxy.

```bash
auscult parse-listing <saved-listing.json>   # verify attribution offline
```

### The richest artefact: `LowBatteryLog`

When iOS shuts down for low battery it writes a report recording the
awake/standby split, the foreground app, and **every power assertion held at
that moment** — which names the subsystems that were preventing sleep and for
how long. Read across several events it is more informative than any
measurement the host can take.

The awake share is the figure that matters, because consumption follows from it
almost mechanically:

```
✗ Times the battery ran flat: 4 in 5.5 days
✗ Time awake rather than asleep: 40.72%   (a lightly-used phone is under 15%)
✗ Longest unbroken screen-on stretch: 3.75 h
! In the foreground when it died: a game (2×), a social app (1×), a video app (1×)
  Subsystems preventing sleep: runningboardd/SpringBoard 3h45m,
    app<game> 1h47m, audiomxd VAD 1h9m, bluetoothd BTStack 57m
```

The display is reported separately from the other assertions rather than ranked
alongside them, because at 2–3 W whenever lit it dwarfs everything else and
would otherwise bury the interesting entries.

### Force-quitting apps makes drain worse — measured

Widely-repeated advice, and this tool disproves it with numbers. On the test
device, with the display off and charging paused throughout:

| State | Idle system load |
|---|---|
| Baseline | **682 mW** |
| Immediately after force-quitting 31 apps | **5,720 mW** (peak 11.4 W) |
| 5 minutes later | 2,388 mW |
| 10 minutes later | *see below* |

Only 7 of the 33 apps came back, so the elevated draw was not the apps
returning — it was iOS rebuilding the state it had just been made to discard:
Spotlight re-indexing, widgets re-rendering, caches and on-device models
re-warming. Load was high enough that the battery **discharged while plugged
in**, because system draw exceeded what the paused charger supplied.

A suspended app holds RAM but uses no CPU. Terminating it converts a free
resource into an expensive one. The lever that actually helps is Background App
Refresh, which governs whether an app gets *woken*.

The `drain` command says this in its interpretation, because a user who has
just closed everything and then measures will otherwise draw exactly the wrong
conclusion.

### Storage without a cable

`com.apple.afc` — the Apple File Conduit — answers `GetDeviceInfo` with the
volume's byte counts, and runs over the same lockdown session as everything
else. So storage totals no longer depend on Apple Configurator, which is
USB-only:

```
✓ Storage — 109.87 GB free of 511.36 GB
✓ Free space: 21.49%   expected: keep above 10%
– Usage by category: — the per-category split comes from Apple Configurator,
  which only works over USB
```

AFC is a binary protocol rather than plist-based: a fixed 40-byte header with
little-endian fields, then NUL-separated strings. One trap worth recording —
`0x0A` is `GET_FILE_INFO` and `0x0B` is `GET_DEVINFO`, not the reverse.
Swapping them returns `st_size`, `st_mtime` and friends for the root directory,
which reads as a perfectly plausible reply until you go looking for
`FSFreeBytes`.

### Where the RAM went

Jetsam reports carry a complete process table captured at the moment iOS killed
something for memory — a better census than any live query, because it is
precisely the snapshot of the worst moment.

```bash
auscult memory --limit 20
```

On a 12 GB device this found 434 resident processes, 581 MB free, a 2,587 MB
compressed page store, and one suspended app holding 1,245 MB. Processes are
grouped by category (kernel, system UI, Apple Intelligence, media processing,
daemons, apps) because "3 GB of apps" is a legible answer and a list of 434
process names is not.

Suspended apps are called out separately: iOS keeping an app in memory is
correct behaviour and costs no CPU, but under pressure that is exactly the
memory being compressed and decompressed, so it is the cheapest thing to free.

### Naming the culprit

iOS exposes no per-process energy API to third parties. The real numbers live in
`CurrentPowerlog.PLSQL`, which only ships inside a sysdiagnose — and
`devicectl device sysdiagnose` wants interactive consent on a TTY.

But there is a better source that needs nothing but a directory listing. iOS
writes a report every time a process exceeds a resource limit — sustained CPU,
excessive disk writes, too many wakeups — and **names the file after the
culprit**. The `systemCrashLogs` domain exposes those, so counting and weighting
them attributes misbehaviour to specific apps.

```bash
auscult energy                      # ranked offenders
auscult energy --detail Twitter     # every report, with the numbers
```

CPU-exhaustion reports carry the strongest signal, because iOS only writes one
when a process held high CPU for minutes:

```
27 reports  Twitter  27 × cpu exhaustion
    detail: 90 seconds cpu time over 99 seconds (91% cpu average),
            exceeding limit of 50% cpu over 180 seconds
```

Kinds are weighted rather than summed — a minute of pegged CPU costs far more
energy than a burst of disk writes — and the output states plainly that this is
evidence of misbehaviour rather than a direct measurement, with Settings ›
Battery as the authority.

Two attribution traps worth knowing: jetsam reports are named `JetsamEvent-…`
for the *event*, not the process that died, so ranking on the filename invents a
process called "JetsamEvent"; and totals from opened reports must say how many
were opened, or "450 s of CPU" reads as the whole history when it is five
episodes of twenty-seven.

`RunningAppsProbe` complements this with third-party residency, stated equally
carefully: iOS holds recently-used apps suspended in memory, so residency alone
is not evidence of consumption.

### Guided tests never guess

A prompt that times out is recorded as `skipped`, never as a defect. Reporting a
broken display because nobody was holding the phone is the worst answer a
diagnostic can give, so "nobody answered" and "the user saw a fault" are
different outcomes in the wire protocol, not just in the wording.

The touch test names the cells that never responded (`r1c3, r2c3, …`), which
turns "the touchscreen is faulty" into "the top-right corner is dead" — the
difference between a guess and a repair.

### Bugs that only real hardware finds

Worth recording, because none was visible in a simulator:

1. **The watchdog kill.** Test bodies ran on the main actor, so 14 s of all-core
   load blocked the run loop and iOS killed the app. The host saw the connection
   drop mid-test. Test bodies are now detached.
2. **The optimiser deleted the benchmark.** With the result discarded, the whole
   loop was removed; zero elapsed time gave infinite throughput, and
   `Int(infinity)` traps. Results now escape to a sink, a measurable elapsed
   time is asserted, and the formatters are total.
3. **Storage measured memory, not flash.** Both paths went through the buffer
   cache and reported 7.7 GB/s. With `F_NOCACHE` and `fsync`, the real figure is
   2.6 GB/s.
4. **A healthy magnetometer read zero.** `CMDeviceMotion` only populates the
   magnetic field in a magnetically-referenced frame; `xArbitraryZVertical`
   leaves it at zeros.
5. **A dead touchscreen that wasn't.** The capture view was a `UIViewRepresentable`
   with no intrinsic content size, so SwiftUI laid it out at zero and no touch
   ever reached it — reported as 0 of 40 cells on a perfectly good digitizer. It
   now counts raw events, so that failure mode is self-diagnosing.
6. **Three dead rear cameras that weren't.** A phone face-up on a desk has three
   covered lenses. The fix is that read noise distinguishes them: a live sensor
   in the dark still returns σ ≈ 0.1, while a genuinely dead one returns
   *exactly* zero. Dark is now reported as unverified, never as a fault.
7. **A silent speaker that worked.** `AVAudioSession` in `.measurement` mode
   drops output gain far enough that the microphone two centimetres away
   couldn't hear a 1 kHz tone. In `.default` mode the same tone recovers at
   63 dB. The test now also reads `outputVolume` first, because media volume
   being down is the most common reason a loopback test "fails".

### Constraints worth knowing

- The agent must be **in the foreground**. iOS suspends backgrounded apps and
  the listening socket dies with them.
- A **free** developer account allows only 3 sideloaded apps and expires
  profiles after 7 days, so the agent needs reinstalling weekly. The paid
  programme removes both limits.
- First install requires trusting the developer profile on the device
  (Settings › General › VPN & Device Management) — that needs the passcode.

## Icons

Both icons come from one vector source, `Scripts/generate-icons.sh` -- a pulse
trace with radiating "listening" arcs, after the auscultation the project is
named for. The host puts the trace on a dark field (the trace is the sound
source); the agent runs it through a device on a light field (the device is
what is being listened to).

The script exists because iOS and macOS want opposite geometry from the same
artwork:

| | iOS / iPadOS | macOS |
|---|---|---|
| shape | full bleed, square | squircle drawn in, ~10% margin |
| corners | none -- the system masks | drawn here; nothing masks on macOS |
| alpha | **must not have a channel at all** | required, for the margin |

That alpha rule is the one that bites. App Store validation rejects an icon
that merely *has* an alpha channel, even one opaque in every pixel, and
`rsvg-convert` always emits RGBA while neither `sips` nor `iconutil` can drop
the channel. The script redraws through a `CGBitmapContext` with
`noneSkipLast`, which makes ImageIO write a 24-bit PNG.

## Distribution

**The agent (iOS + iPadOS) ships through TestFlight.** One binary covers both
-- `TARGETED_DEVICE_FAMILY: "1,2"`. Build it with `Scripts/archive-agent.sh`,
which is separate from `build-agent.sh` on purpose: that script picks the
newest Xcode so a device on an iOS seed gets a matching SDK, and App Store
Connect rejects anything built with a beta Xcode. The archive script pins the
release Xcode and refuses to run on a seed.

Note that the archive signs with Apple Development and the wildcard profile;
the distribution identity and the Store profile are applied at *export*.
Inspecting the archive instead of the `.ipa` will tell you the wrong thing.

Upload with `UPLOAD=1 Scripts/archive-agent.sh`. This needs **no App Store
Connect API key and no app-specific password**: `destination: upload` in the
export options rides the account already signed into Xcode. That is easy to
miss, because every `altool` invocation refuses to run without one or the
other, which makes CLI upload look credential-gated when it is not.

"Upload succeeded" is not the final word either. App Store Connect runs its
beta-SDK check during *processing*, after the transfer finishes, and rejects a
seed-built binary by email at that point rather than at upload time.

**The macOS app cannot ship through TestFlight, and this is architectural
rather than a signing problem.** macOS TestFlight is reachable only through
the Mac App Store channel, which mandates `com.apple.security.app-sandbox`.
The sandbox denies `connect()` to `/var/run/usbmuxd`, which is the one thing
this app exists to do -- measured directly, same bundle, same
`com.apple.security.device.usb` entitlement:

```
sandboxed      DENIED: Operation not permitted (errno 1)
not sandboxed  CONNECTED to usbmuxd
```

`com.apple.security.device.usb` governs IOUSBHost device access, not a system
daemon's socket, and no public entitlement covers the latter. The app also
spawns `xcrun devicectl` and `cfgutil`, which a sandboxed process may not do.
Shipping it on the Mac App Store would mean deleting the transports that make
it useful.

The correct macOS path is **Developer ID plus notarisation** -- distributed
outside the store, no sandbox required, everything above keeps working. That
route has no TestFlight, so beta distribution there is a direct download.

### Notarising the Mac app

```
Scripts/notarize-mac.sh          # → build/mac-release/Auscult-<version>.zip
RELEASE=1 Scripts/notarize-mac.sh  # …and publish it as a GitHub Release
```

GitHub Releases are the Mac app's beta channel, since TestFlight is closed to
it. Each release is tagged `mac-v<version>` and carries two assets with fixed
names, `Auscult-mac.zip` and `Auscult-mac.pkg`, so
`releases/latest/download/Auscult-mac.zip` always serves the newest build.

It archives `Mac/Auscult.xcodeproj` (generated by xcodegen from
`Mac/project.yml`), exports with `method: developer-id` and `destination:
upload`, waits for Apple, fetches the stapled app with `-exportNotarizedApp`,
verifies it, and zips it with `ditto`.

**No certificate or credentials to manage.** There is no Developer ID
certificate on this Mac and none is needed: Xcode signs with a *cloud-managed*
Developer ID certificate and submits to the notary service on the account
already signed into Xcode. `codesign` + `notarytool` would need a local
certificate and an app-specific password or API key; this route needs neither.
That is also why the Mac app now has an Xcode project at all --
`Scripts/bundle-app.sh` stays for quick ad-hoc local builds.

The script refuses to finish unless every one of these holds, since each is
something a downloader's Mac checks:

- both executables -- the app and the embedded `Helpers/auscult` -- carry a
  `Developer ID Application` signature, hardened runtime, and a secure timestamp
- `codesign --verify --deep --strict` passes
- the notarisation ticket is stapled, so first launch works offline
- Gatekeeper accepts it: `source=Notarized Developer ID`

Verified further by hand for 0.1.0: a copy unzipped and marked with Safari's
quarantine flag -- which is what triggers Gatekeeper's full first-launch check
-- is accepted, and the embedded CLI still reaches devices over USB under the
hardened runtime.

Two traps the project avoids, both found the hard way:

- **Target names must differ by more than case.** Xcode keys each target's
  intermediates directory by target name, so on a case-insensitive disk
  `Auscult.build` and `auscult.build` are one directory. With the CLI target
  named `auscult` the two targets shared object files and link lists, and the
  embedded "CLI" came out as a second copy of the GUI -- which then sat in its
  event loop looking exactly like a hung permission prompt. The target is
  `AuscultCLI`; only its product is named `auscult`.
- **The CLI target needs `SKIP_INSTALL`.** Otherwise the archive also installs
  it at `/usr/local/bin`, which makes it a "generic" archive that cannot be
  exported as an app. The script checks for this before exporting.

## Roadmap

**Phase 5 — baselines.** The CSV export exists so two runs of the same device
can be diffed. Storing baselines turns "91.2% health" into "down 1.4 points in
six weeks", which is the number that actually predicts a failure.
