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

## Roadmap

**Phase 2 (next) — on-device agent.** A signed iOS companion app, sideloaded
with the host's Apple Development identity, exercising what the host can't
reach: full-screen dead-pixel sweep, multitouch grid, every `AVCaptureDevice`,
speaker→mic loopback with FFT verification, accel/gyro/mag/baro sanity, GNSS
fix, haptics, thermal curve under sustained load.

**Phase 3 — stability history.** Kernel panic and jetsam log retrieval via
`com.apple.crashreportcopymobile`, parsed into a panic-cause timeline. The
service client is stubbed; the capability is declared and reports as
unsupported until it lands.

**Phase 4 — baselines.** The CSV export exists so two runs of the same device
can be diffed. Storing baselines turns "91.2% health" into "down 1.4 points in
six weeks", which is the number that actually predicts a failure.
