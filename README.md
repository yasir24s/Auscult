# Auscult

Auscult diagnoses iPhone and iPad hardware and system health from a Mac, and it
keeps working on iOS beta builds. An optional app on the device covers what a
Mac cannot test: the touchscreen, display, cameras, speaker, microphones and
motion sensors.

Tested on an iPhone 17 Pro Max and an iPad Air 13-inch (M3) on iOS 27, through
the seeds and the release build, from macOS 27.2 with Xcode 27.0. An excerpt
from the iPhone's report, with some notes shortened and the serial's last
characters replaced:

```
POWER & BATTERY
  ✓ Battery — 91.0% of original capacity, 619 cycles
      ✓ Battery health: 91.04%  (Very good — Barely worn — battery life is close to what it was new.)
          expected: 80% or more is within Apple's design
        Wear pace: On or ahead of Apple's design
        Design capacity: 4,768 mAh
        Full charge capacity: 4,485 mAh
        Cycle count: 619 cycles  (62% of the 1000 cycles Apple designs this model to reach at 80% capacity)
        Battery serial: ••••••••••••••X7Q2  (hidden except the last 4 characters, which match the label on the cell)
      ✓ Cell voltage: 3.94 V  (varies with state of charge)
        Cell temperature (last recorded): 22°C  (from the battery's stored boot/charge record, not a live sensor)
      ✓ Unexpected power-off reboots: 0
        Adapter power: 45 W  (pd charger)
```

## Install

**Mac app** (macOS 14 or later): download the
[installer](https://github.com/yasir24s/Auscult/releases/latest/download/Auscult-mac.pkg)
or the [zip](https://github.com/yasir24s/Auscult/releases/latest/download/Auscult-mac.zip)
from [Releases](https://github.com/yasir24s/Auscult/releases). Both are signed
with Developer ID and notarised by Apple. The installer puts Auscult in
Applications; with the zip, move it there yourself. The command-line tool ships
inside the app at `Auscult.app/Contents/Helpers/auscult`.

**On-device agent** (iOS and iPadOS 17 or later): in TestFlight beta, or build
it from source with `Scripts/build-agent.sh`.

## Why beta builds don't break it

Third-party iOS tools tend to break every September because they hard-code
what the OS looks like. Auscult is built the other way round:

1. **Apple's own stack is the primary transport.** `devicectl` ships inside
   Xcode, and Apple updates it in step with every build, including internal
   trains. Whatever pairing or tunnel scheme a seed introduces, that binary
   already speaks it.
2. **No version checks.** Not one line branches on an iOS version. Each
   transport tests what it can actually do against the device in front of it
   and advertises those [capabilities](Sources/AuscultKit/Model/Capability.swift);
   each probe declares what it needs. A seed that moves a service costs one
   capability, not the app.
3. **Every field is read through a candidate list, newest first.** Apple has
   already deprecated `hardwareProperties` in favour of `properties`. Reading
   both means that neither the removal of the old field nor another reshuffle
   of the new one costs a reading. See
   [`DynamicValue`](Sources/AuscultKit/Transport/DynamicValue.swift).
4. **Subsystems, not process names.** `mediaserverd` no longer exists on iOS 27;
   it became `mediaplaybackd` and `audiomxd`. Asking whether *some* media daemon
   is alive survives that change. Checking for one name would report healthy
   hardware as dead.
5. **Unexpected failures are loud.** A probe that throws is reported as `error`,
   separately from `unsupported`. That split is the early warning that a new
   build has moved something.

## Architecture

```
DiagnosticSession
├── TransportRouter          picks who answers what, caches, falls back
│   ├── CoreDeviceTransport  devicectl · breadth + beta immunity
│   ├── LockdownTransport    usbmux → lockdownd → diagnostics relay · depth
│   └── CfgutilTransport     Apple Configurator · IMEI, disk usage, MACs
└── ProbeEngine              runs probes, assembles the report
```

Probes never know which transport served them. A probe asks for a
`TransportRequest`, and the router finds a transport that advertised the
matching capability. If that transport fails at request time, which is exactly
what an OS seed looks like, the router demotes it and tries the next one.

### The deep path

`CoreDevice` exposes no battery gas gauge and no NAND wear. Those come from a
native Swift implementation of the classic stack:

```
usbmuxd (unix socket, plist framing)   ← pair records without root
   └── lockdownd :62078
         ├── QueryType / StartSession
         ├── mutual TLS on the same socket   ← SecIdentity from the pair record
         └── StartService
               └── com.apple.mobile.diagnostics_relay
                     └── IORegistry · MobileGestalt · GasGauge
```

Two parts of this were the hard bits, and the source documents both:

- **[`HostIdentity`](Sources/AuscultKit/Services/HostIdentity.swift).** There is
  no public API to build a `SecIdentity` from a loose certificate and key, so
  Auscult creates a throwaway keychain in a temporary directory, imports the
  pair record's credentials, takes the identity, and deletes the keychain. The
  login keychain is never touched.
- **[`BlockingIO`](Sources/AuscultKit/Services/BlockingIO.swift).** Secure
  Transport's IO callbacks are blocking C functions. Calling them from an
  `async` context parks a cooperative thread inside a syscall, and with several
  transports probing at once that exhausts the pool and deadlocks the process.
  Every blocking chain now runs on a real thread and is awaited through a
  continuation.

## Usage

To build from source:

```bash
swift build -c release
./Scripts/bundle-app.sh release      # builds build/Auscult.app
```

```bash
auscult doctor                 # which data paths this Mac has
auscult list                   # every visible device
auscult run                    # diagnose the first connected device
auscult run <device> --json    # machine-readable report
auscult run <device> --csv     # one row per metric, for diffing two runs
```

`<device>` is part of the device's name, or the last four characters of its
UDID as `auscult list` prints them.

For when something stops working after an OS update:

```bash
auscult usbmux                 # mux layer + pair record state
auscult relay <device>         # trace the deep handshake step by step
auscult ioreg --name AppleSmartBattery   # dump any IORegistry node
auscult pairtest <file>        # verify a pair record builds a TLS identity
```

`auscult relay` checks the five separate failure points (mux, pair record, TLS
identity, session, service) one at a time. From the outside they look almost
identical, so stepping through them turns guesswork into a diagnosis that
takes seconds.

## What it measures

| Section | Source | Notes |
|---|---|---|
| Identity | CoreDevice | model, board, chip, cores, biometrics, ECID, serial |
| Software | CoreDevice | version, build, train, **seed detection** |
| Integrity | CoreDevice | production fuse, sealed system volume, Developer Mode |
| Battery | diagnostics relay | health and wear judged against Apple's rating for the model, capacities, cell serial, voltage, unexpected power-offs, adapter |
| Storage | cfgutil, AFC | capacity, free-space grading, per-category usage |
| Display | CoreDevice | geometry, scale, refresh, HDR |
| Radios | cfgutil | IMEI ×2, ICCID ×2, baseband, Wi-Fi/BT MACs, activation |
| Subsystems | CoreDevice | liveness of 12 subsystems, by daemon group |
| Apps | CoreDevice | inventory, developer-signed apps |

### What it does not claim

The Mac can only read what iOS chooses to report. Dead pixels, touch digitizer
coverage, per-lens camera capture, speaker and microphone loopback, gyroscope
bias, GNSS time to fix and haptics **cannot** be tested from a Mac. Auscult
reports those as "requires the on-device agent" instead of leaving them out,
so the report shows what was not measured as well as what was.

Two more gaps come from iOS 27 itself. The relay's `NAND` request returns
`NANDInfoDeprecated`, because Apple removed it, and Auscult says so instead of
inventing a wear figure. The battery no longer reports a live temperature over
USB either, so a stored value is shown as "last recorded" and never graded.

### Identifiers stay private

Reports get pasted into forums and sale listings, so Auscult masks every
identifier that names a device, SIM or person: serial numbers (device and
battery), UDID, ECID, IMEI, ICCID and phone number keep only their last four
characters, and Wi-Fi and Bluetooth MAC addresses keep their last two octets.
The masking applies everywhere: the app, the JSON and CSV exports, the raw
`ioreg`/`relay` dumps, and error messages. The visible tail is enough to check
a reading against Settings › General › About or the label on the cell.

## The on-device agent

Some hardware cannot be tested from a Mac at all. No API reports a stuck
subpixel, and the Mac cannot spin a gyroscope. `Agent/` is a signed iOS and
iPadOS app that runs those tests on the device and reports back.

The Mac reaches it over the **cable**. The agent opens a TCP listener on the
device's loopback interface, and usbmuxd tunnels a Mac-side socket to it. That
needs no Bonjour, no Wi-Fi, no Local Network permission prompt, and no pairing
beyond the one the Mac already has. OS seeds don't change usbmux port
forwarding, so this works the same on any iOS version.

The **agent owns the catalogue**. The Mac asks which tests exist and builds one
probe per entry, so adding a test to the agent needs no change on the Mac.

```bash
Scripts/build-agent.sh              # build, sign, install
auscult agent                        # list what the device can test
auscult agent --test compute.gpu     # run one test
auscult run <device> --guided        # everything, including the guided checks
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
| Storage | write 1.5 GB/s, read 2.6 GB/s, cache-bypassed and byte-verified |
| Display | 1320×2868 at 120 Hz, EDR headroom 8× |
| Biometrics | Face ID present and enrolled |
| Display sweep | guided: 5 colour fields, **5/5 clean** |
| Touch digitizer | guided: **40/40 cells**, faults localised by cell |
| Cameras | all 6 lenses enumerated, per-lens frame statistics |
| Speaker & mics | **tone recovered at 63 dB**, 3 microphones enumerated |
| Bluetooth | **54 advertisers heard**, strongest −29 dBm |
| GNSS | time to first fix and accuracy (coordinates withheld) |

Two newer tests work differently from the rest:

- **Battery health.** iOS gives apps no battery-health API, so the agent asks
  for Maximum Capacity (and, from iPhone 15 on, Cycle Count) as Settings shows
  them, then judges them against what Apple rates that model's battery to
  reach. The result says the figures were entered by hand. The Mac app reads
  the same battery directly and uses the same judgement.
- **RAM pressure.** It fills memory in verified chunks until iOS reports
  critical pressure, stopping well short of the app's own limit. It asks before
  it starts and is left out of Run All, because on a phone with less headroom
  it may close other apps.

### Standalone mode

The agent runs its whole catalogue with no Mac attached. That is the default
tab; the Mac link is the secondary one.

This matters for more than convenience. The first agent build in TestFlight
could not run a single check on its own: it opened on a "waiting for the Mac"
screen, so nobody could test it without sitting at this Mac with a cable.

The tests never needed a Mac. `AgentTest.run(context:)` takes three closures
and nothing else. What needed one was the code that *drove* them, which lived
inside `AgentServer` next to the socket. `DiagnosticRunner` now owns that code:
the detached-task hop that keeps the compute tests off the main actor and away
from the watchdog, the idle-timer window, the prompt continuations, and the
result store. The Mac path goes through the same runner, via `on…` hooks that
are nil when running standalone, so there is one implementation to maintain.

`Run All` covers everything that works unattended. Interactive tests are left
out on purpose: each waits for a person (45 s for the guided checks, 5 minutes
for the battery form), so sweeping them would produce minutes of timeouts
reported as failures. They stay individually runnable and are marked "needs
you". Stop cancels a running test straight away, including one that is waiting
on a prompt.

## Investigating battery drain

`auscult drain` is a dedicated workflow. The ordinary probe reports whatever
the device happens to be doing, which says very little about drain:

```bash
auscult drain --wait 20 --seconds 60    # lock the screen during the countdown
```

It reads `CurrentNits` from `AppleARMBacklight`, so it knows whether the panel
was actually dark, and **grades against different thresholds accordingly**:
3 W is unremarkable with the screen lit and a significant finding with it off.
Without that check, the measurement would rest on the operator's word.

The report also derives figures from the PMU's accumulators: mean draw while
the device was on battery, mean system load since boot, charger conversion
loss, and a projected runtime from pack energy divided by measured draw.

### Paired accessories

An Apple Watch cannot be diagnosed over a cable, and the hardware invites the
opposite conclusion. Plug a Watch into a Mac and `ioreg` shows:

```
USB Vendor Name  = "Apple Inc."
USB Product Name = "Apple Watch Magnetic Charging Cable"
```

The Mac sees *the cable*, which enumerates as a USB device in its own right,
and nothing behind it. The charger is an induction coil with no data lines, so
no configuration can turn it into a link. `auscult pair` detects attached
power-only accessories and says so, rather than leaving someone to conclude
their Watch is broken or unsupported.

What works instead: a Watch pairs to a phone and forwards its crash and
resource reports through it. Those land in the phone's crash-log directory
under `ProxiedDevice-<id>/`, so a useful slice of Watch health is reachable
without pairing the Watch to Xcode.

This started as a bug. The index attributed those reports to the phone, so a
watch app that crashed 131 times showed up in the iPhone's offender ranking.
Reports now carry an `Origin`, rankings cover the phone alone by default, and
`AccessoryHealthProbe` reports accessories separately.

An accessory gives crash and resource history, which is enough to identify an
app misbehaving on the wrist. It gives no battery gauge, IORegistry or agent,
because none of those reach through the proxy.

```bash
auscult parse-listing <saved-listing.json>   # verify attribution offline
```

### The most useful record: `LowBatteryLog`

When iOS shuts down for low battery, it writes a report recording the
awake/standby split, the foreground app, and **every power assertion held at
that moment**. The assertions name the subsystems that were keeping the device
awake, and for how long. Read across several events, these reports say more
than any measurement the Mac can take.

The awake share matters most, because consumption follows from it almost
mechanically:

```
✗ Times the battery ran flat: 4 in 5.5 days
✗ Time awake rather than asleep: 40.72%   (a lightly-used phone is under 15%)
✗ Longest unbroken screen-on stretch: 3.75 h
! In the foreground when it died: a game (2×), a social app (1×), a video app (1×)
  Subsystems preventing sleep: runningboardd/SpringBoard 3h45m,
    app<game> 1h47m, audiomxd VAD 1h9m, bluetoothd BTStack 57m
```

The display is reported apart from the other assertions. At 2–3 W whenever
it is lit, it would otherwise outrank everything else and bury the useful
entries.

### Force-quitting apps made drain worse

This is widely repeated advice, and on the test device the numbers went the
other way. The display was off and charging was paused throughout:

| State | Idle system load |
|---|---|
| Baseline | **682 mW** |
| Immediately after force-quitting 31 apps | **5,720 mW** (peak 11.4 W) |
| 5 minutes later | 2,388 mW |

Only 7 of those apps came back, so the extra draw was not the apps returning.
It was iOS rebuilding the state it had just been made to discard: Spotlight
re-indexing, widgets re-rendering, caches and on-device models warming up
again. The load was high enough that the battery **discharged while plugged
in**, because the system drew more than the paused charger supplied.

A suspended app holds RAM but uses no CPU, so terminating it turns a free
resource into an expensive one. Background App Refresh is the setting that
actually helps, because it controls whether an app gets *woken*.

The `drain` command explains this in its interpretation. Otherwise someone who
has just closed everything and then measures would draw exactly the wrong
conclusion.

### Storage without a cable

`com.apple.afc` (the Apple File Conduit) answers `GetDeviceInfo` with the
volume's byte counts, and it runs over the same lockdown session as everything
else. Storage totals therefore no longer depend on Apple Configurator, which
works only over USB:

```
✓ Storage — 109.87 GB free of 511.36 GB
✓ Free space: 21.49%   expected: keep above 10%
– Usage by category: — the per-category split comes from Apple Configurator,
  which only works over USB
```

AFC is a binary protocol rather than plist-based: a fixed 40-byte header with
little-endian fields, then NUL-separated strings. One trap: `0x0A` is
`GET_FILE_INFO` and `0x0B` is `GET_DEVINFO`, not the other way round. Swapping
them returns `st_size`, `st_mtime` and similar fields for the root directory,
which looks like a plausible reply until you look for `FSFreeBytes`.

### Where the RAM went

Jetsam reports carry a complete process table, captured at the moment iOS
killed something to free memory. That makes them a better census than any live
query, because they record the worst moment.

```bash
auscult memory --limit 20
```

On a 12 GB device this found 434 resident processes, 581 MB free, a 2,587 MB
compressed page store, and one suspended app holding 1,245 MB. Processes are
grouped by category (kernel, system UI, Apple Intelligence, media processing,
daemons, apps), because "3 GB of apps" is a readable answer and a list of 434
process names is not.

Suspended apps are listed separately. iOS keeping an app in memory is correct
behaviour and costs no CPU, but under pressure that is exactly the memory being
compressed and decompressed, so it is the cheapest memory to free.

### Naming the culprit

iOS gives third parties no per-process energy API. The real numbers live in
`CurrentPowerlog.PLSQL`, which ships only inside a sysdiagnose, and
`devicectl device sysdiagnose` wants interactive consent on a TTY.

A directory listing turns out to be enough. iOS writes a report every time a
process exceeds a resource limit (sustained CPU, excessive disk writes, too
many wakeups) and **names the file after the culprit**. The `systemCrashLogs`
domain exposes those reports, so counting and weighting them attributes
misbehaviour to specific apps.

```bash
auscult energy                      # ranked offenders
auscult energy --detail Twitter     # every report, with the numbers
```

CPU-exhaustion reports carry the strongest signal, because iOS writes one only
when a process held high CPU for minutes:

```
27 reports  Twitter  27 × cpu exhaustion
    detail: 90 seconds cpu time over 99 seconds (91% cpu average),
            exceeding limit of 50% cpu over 180 seconds
```

Report kinds are weighted rather than summed, since a minute of pegged CPU
costs far more energy than a burst of disk writes. The output states that this
is evidence of misbehaviour, not a direct measurement, and points to
Settings › Battery as the authority.

Two attribution traps. Jetsam reports are named `JetsamEvent-…` after the
*event*, not the process that died, so ranking on the filename invents a
process called "JetsamEvent". And totals from opened reports must say how many
were opened, or "450 s of CPU" reads as the whole history when it covers five
episodes out of twenty-seven.

`RunningAppsProbe` adds third-party residency, stated just as carefully: iOS
keeps recently used apps suspended in memory, so residency alone is not
evidence of consumption.

### Guided tests never guess

A prompt that times out is recorded as `skipped`, never as a defect. Reporting
a broken display because nobody was holding the phone is the worst answer a
diagnostic can give, so "nobody answered" and "the user saw a fault" are
different outcomes in the wire protocol, not only in the wording.

The touch test names the cells that never responded (`r1c3, r2c3, …`). That
turns "the touchscreen is faulty" into "the top-right corner is dead", which
is something a repair can act on.

### Bugs that only real hardware found

None of these showed up in a simulator:

1. **The watchdog kill.** Test bodies ran on the main actor, so 14 s of
   all-core load blocked the run loop and iOS killed the app. The Mac saw the
   connection drop mid-test. Test bodies are now detached.
2. **The optimiser deleted the benchmark.** With the result discarded, the
   compiler removed the whole loop. Zero elapsed time gave infinite
   throughput, and `Int(infinity)` traps. Results now escape to a sink, a
   measurable elapsed time is asserted, and the formatters handle every value.
3. **Storage measured memory, not flash.** Both paths went through the buffer
   cache and reported 7.7 GB/s. With `F_NOCACHE` and `fsync`, the real figure
   is 2.6 GB/s.
4. **A healthy magnetometer read zero.** `CMDeviceMotion` fills in the magnetic
   field only in a magnetically referenced frame; `xArbitraryZVertical` leaves
   it at zero.
5. **A dead touchscreen that wasn't.** The capture view was a
   `UIViewRepresentable` with no intrinsic content size, so SwiftUI laid it out
   at zero size and no touch ever reached it. A perfectly good digitizer
   scored 0 of 40 cells. The test now counts raw events, so that failure
   identifies itself.
6. **Three dead rear cameras that weren't.** A phone lying face up on a desk
   has three covered lenses. Read noise tells them apart: a live sensor in the
   dark still returns σ ≈ 0.1, while a dead one returns *exactly* zero. A dark
   frame is now reported as unverified, never as a fault.
7. **A silent speaker that worked.** In `.measurement` mode, `AVAudioSession`
   drops output gain so far that the microphone two centimetres away couldn't
   hear a 1 kHz tone. In `.default` mode the same tone comes back at 63 dB. The
   test also reads `outputVolume` first, because a lowered media volume is the
   most common reason a loopback test "fails".

### Building the agent yourself

TestFlight installs need none of this; it applies to builds from source.

- The agent must be **in the foreground** to talk to the Mac. iOS suspends
  backgrounded apps, and the listening socket goes with them.
- A **free** developer account allows only 3 sideloaded apps and expires
  profiles after 7 days, so a self-built agent needs reinstalling weekly. The
  paid programme removes both limits.
- The first install needs the developer profile trusted on the device
  (Settings › General › VPN & Device Management), which asks for the passcode.

## Icons

Both icons come from one vector source in `Scripts/generate-icons.sh`: a pulse
trace with radiating "listening" arcs, after the auscultation the project is
named for. The Mac icon puts the trace on a dark field (the trace is the sound
source). The agent icon runs it through a device on a light field (the device
is what is being listened to).

The script exists because iOS and macOS want opposite geometry from the same
artwork:

| | iOS / iPadOS | macOS |
|---|---|---|
| shape | full bleed, square | squircle drawn in, ~10% margin |
| corners | none (the system masks them) | drawn here; nothing masks on macOS |
| alpha | **must not have a channel at all** | required, for the margin |

The alpha rule is the one that bites. App Store validation rejects an icon that
merely *has* an alpha channel, even one that is opaque in every pixel.
`rsvg-convert` always emits RGBA, and neither `sips` nor `iconutil` can drop
the channel. The script redraws through a `CGBitmapContext` with
`noneSkipLast`, which makes ImageIO write a 24-bit PNG.

## Distribution

### The agent: TestFlight

One binary covers iPhone and iPad (`TARGETED_DEVICE_FAMILY: "1,2"`). Build it
with `Scripts/archive-agent.sh`, which is separate from `build-agent.sh` on
purpose. `build-agent.sh` picks the newest Xcode, so a device on an iOS seed
gets a matching SDK. App Store Connect rejects anything built with a beta
Xcode, so the archive script pins the release Xcode and refuses to run on a
seed.

The archive is signed with Apple Development and the wildcard profile; the
distribution identity and the Store profile are applied at *export*. Inspecting
the archive instead of the `.ipa` will mislead you.

Upload with `UPLOAD=1 Scripts/archive-agent.sh`. This needs **no App Store
Connect API key and no app-specific password**: `destination: upload` in the
export options uses the account already signed into Xcode. That is easy to
miss, because every `altool` invocation refuses to run without one or the
other, which makes command-line upload look like it needs credentials.

"Upload succeeded" is not the final word either. App Store Connect runs its
beta-SDK check during *processing*, after the transfer finishes, and rejects a
seed-built binary by email at that point.

### The Mac app: Developer ID, not TestFlight

**The Mac app cannot ship through TestFlight, and the reason is architectural
rather than a signing problem.** On macOS, TestFlight goes through the Mac App
Store channel, which requires `com.apple.security.app-sandbox`. The sandbox
denies `connect()` to `/var/run/usbmuxd`, the one thing this app exists to do.
Measured directly, with the same bundle and the same
`com.apple.security.device.usb` entitlement:

```
sandboxed      DENIED: Operation not permitted (errno 1)
not sandboxed  CONNECTED to usbmuxd
```

`com.apple.security.device.usb` governs access to IOUSBHost devices, not to a
system daemon's socket, and no public entitlement covers the latter. The app
also launches `xcrun devicectl` and `cfgutil`, which a sandboxed process may
not do. Shipping on the Mac App Store would mean deleting the transports that
make the app useful.

So the Mac app ships with **Developer ID and notarisation**, outside the store,
with no sandbox and everything above still working. That route has no
TestFlight, so GitHub Releases act as the beta channel.

### Notarising the Mac app

```
Scripts/notarize-mac.sh             # → build/mac-release/Auscult-<version>.zip
RELEASE=1 Scripts/notarize-mac.sh   # …and publish it as a GitHub Release
RELEASE=1 Scripts/package-mac-pkg.sh  # add the signed installer to that release
```

Each release is tagged `mac-v<version>` and carries two assets with fixed
names, `Auscult-mac.zip` and `Auscult-mac.pkg`, so
`releases/latest/download/Auscult-mac.zip` always serves the newest build.

`notarize-mac.sh` archives `Mac/Auscult.xcodeproj` (generated by xcodegen from
`Mac/project.yml`), exports with `method: developer-id` and `destination:
upload`, waits for Apple, fetches the stapled app with `-exportNotarizedApp`,
verifies it, and zips it with `ditto`.

**The zip needs no local certificate or credentials.** Xcode signs with a
*cloud-managed* Developer ID certificate and submits to the notary service on
the account already signed into Xcode. `codesign` plus `notarytool` would need
a local certificate and an app-specific password or API key; this route needs
neither. That is also why the Mac app has an Xcode project at all.
`Scripts/bundle-app.sh` stays for quick ad-hoc local builds.

The script refuses to finish unless every one of these holds, since each is
something a downloader's Mac checks:

- both executables (the app and the embedded `Helpers/auscult`) carry a
  `Developer ID Application` signature, hardened runtime, and a secure timestamp
- `codesign --verify --deep --strict` passes
- the notarisation ticket is stapled, so first launch works offline
- Gatekeeper accepts it: `source=Notarized Developer ID`

Verified by hand for 0.1.0 as well: a copy unzipped and marked with Safari's
quarantine flag, which triggers Gatekeeper's full first-launch check, is
accepted, and the embedded CLI still reaches devices over USB under the
hardened runtime.

**The installer is the exception.** `package-mac-pkg.sh` needs a local
`Developer ID Installer` certificate and a `notarytool` keychain profile. It builds the component
package with `pkgbuild`, signs the product with `productbuild`, notarises and
staples it, and checks it with `spctl --assess --type install`.

Three traps the project avoids, all found the hard way:

- **Target names must differ by more than case.** Xcode keys each target's
  intermediates directory by target name, so on a case-insensitive disk
  `Auscult.build` and `auscult.build` are one directory. With the CLI target
  named `auscult`, the two targets shared object files and link lists, and the
  embedded "CLI" came out as a second copy of the GUI. That copy then sat in
  its event loop, looking exactly like a hung permission prompt. The target is
  `AuscultCLI`; only its product is named `auscult`.
- **The CLI target needs `SKIP_INSTALL`.** Otherwise the archive also installs
  it at `/usr/local/bin`, which makes it a "generic" archive that cannot be
  exported as an app. The script checks for this before exporting.
- **macOS 27's `pkgbuild` leaves `BundleIsRelocatable` out** of the component
  plist. Left alone, the installer could put the app wherever an older copy
  happens to live instead of in Applications. The script sets it to `false`
  and reads it back before building.

## Roadmap

**Baselines.** The CSV export exists so two runs of the same device can be
diffed. Storing baselines would turn "91.2% health" into "down 1.4 points in
six weeks", which is the number that actually predicts a failure.
