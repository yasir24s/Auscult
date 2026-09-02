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
        Battery serial: ••••••••••••••15XX
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

What it cannot do is attribute energy to a process — iOS keeps that in its power
log. So `RunningAppsProbe` lists third-party residency as a *shortlist*, stated
carefully: iOS holds recently-used apps suspended in memory, so residency is not
evidence of consumption. Settings › Battery remains the authority on per-app
energy.

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

## Roadmap

**Phase 4 — per-app energy attribution.** The device's own power log
(`CurrentPowerlog.PLSQL`) is the only place iOS attributes energy per process.
It ships inside a sysdiagnose, but `devicectl device sysdiagnose` requires
interactive consent on a TTY, so capturing it needs either a pty or the
`crashreportcopymobile` service. Until then the drain workflow narrows the
candidates and Settings › Battery does the attribution.

**Phase 5 — stability history.** Kernel panic and jetsam log retrieval via
`com.apple.crashreportcopymobile`, parsed into a panic-cause timeline.

**Phase 6 — baselines.** The CSV export exists so two runs of the same device
can be diffed. Storing baselines turns "91.2% health" into "down 1.4 points in
six weeks", which is the number that actually predicts a failure.
