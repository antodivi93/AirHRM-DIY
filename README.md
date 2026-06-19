# AirHRM-DIY

An iOS app that bridges **Apple AirPods Pro 3** heart rate to a standard **Bluetooth LE Heart Rate sensor**, so any fitness device that can pair with a chest strap (cycling computers, sports watches, gym equipment) can read it.

## Why this exists

AirPods Pro 3 expose heart rate to iOS HealthKit, but the data stays locked inside HealthKit — third-party fitness devices can't see it. This app starts an iOS workout session to "wake up" the AirPods sensor, then re-broadcasts the heart rate over BLE using the standard **Heart Rate Service (GATT `0x180D`)**, so external receivers pair with the iPhone as if it were a chest strap.

## Features

- **Auto-start** when AirPods Pro 3 become the active audio output
- **Contact-lost handling**: when no valid HR sample arrives for ~5s, the bridge stops notifying so receivers can fall back to their own wrist sensor (instead of seeing a frozen value)
- **Source identification**: the UI shows whether the current HR sample comes from AirPods or Apple Watch (HealthKit fuses both)
- **BLE robustness**: handles transmit queue back-pressure (`peripheralManagerIsReady`), Bluetooth state changes, app lifecycle, and Core Bluetooth state restoration (`willRestoreState`) for background relaunches
- **App Intents** for Siri and Shortcuts: `Start Heart Rate Bridge` / `Stop Heart Rate Bridge`
- **SwiftUI Previews** for five different UI states

## Architecture

A coordinator pattern. `HeartRateBridge` is an `@MainActor ObservableObject` that orchestrates three specialized components:

- `HealthKitHRSource` — HealthKit authorization, `HKWorkoutSession` + `HKLiveWorkoutBuilder`, sample-source classification (Apple Watch / AirPods / iPhone), recovery of active sessions after background relaunch.
- `HRPeripheralAdvertiser` — owns `CBPeripheralManager`, publishes the GATT Heart Rate Service, manages advertising and transmit queue back-pressure, handles Core Bluetooth state restoration.
- `AudioRouteMonitor` — observes `AVAudioSession.routeChangeNotification` and `UIApplication.didBecomeActiveNotification` to detect AirPods as the active output.

Supporting types: `HRGatt` (static GATT constants), `BridgeState` (state enum with `displayText`), `HeartRateBridgeIntents` (App Intents + `AppShortcutsProvider`).

## Requirements

- iPhone running **iOS 26 or later**
- **AirPods Pro 3** (heart rate sensor required)
- **Xcode 26 or later** on a Mac
- An Apple ID (free — no paid Developer Program required)

## Setup

1. Clone the repo and open `AirHRM-DIY.xcodeproj`.
2. Select the `AirHRM-DIY` target → **Signing & Capabilities**:
   - **Team**: your personal Apple ID team.
   - **Bundle Identifier**: change `com.example.airhrmdiy` to a unique reverse-DNS string of your own.
   - Keep **Automatically manage signing** checked.
3. On the iPhone, enable **Settings → Privacy & Security → Developer Mode**. The iPhone restarts.
4. Connect the iPhone via USB-C, select it as the build destination, hit **⌘R**.
5. On first launch on the iPhone, go to **Settings → General → VPN & Device Management → Trust your Apple ID**.
6. In the app, grant the requested HealthKit and Bluetooth permissions.

Default builds are signed with **Free Provisioning** (no paid Developer Program), which expires after **7 days**. Re-run `⌘R` from Xcode to refresh, or use **AltStore / SideStore** to keep the signature renewed automatically.

## Usage

1. Open the app and tap **Start HR Bridge**, or use the Siri / Shortcuts action of the same name.
2. Put on the AirPods Pro 3. With Auto-Start enabled (default), step 1 is automatic.
3. On your fitness device, scan for a heart rate strap. Pair with **AirHRM-DIY**.
4. Start your activity. The fitness device will record HR from the AirPods via the bridge.

## Pairing with smartwatch-class receivers

If your fitness device is also a smartwatch paired to the same iPhone (notifications, weather, music control), pairing the HR bridge can fail or drop mid-activity.

**Why this happens.** Two BLE connections to the same receiver would originate from the same iPhone MAC address: one for smart features (ANCS / notifications, managed by the watch's companion app), one for the Heart Rate sensor profile published by this app. Many receivers will not maintain both concurrent links from a single source and drop one of them — typically the HR one, because system-level services take priority. The receiver isn't broken and the bridge isn't broken; the two flows are colliding on the same radio identity.

**Per-activity workaround (recommended).** On the receiver, temporarily disable the link to the phone before starting the activity, and re-enable it after:

1. From the watch face, open the controls/shortcut menu (on most Garmin models: hold the `Light` button for ~2s).
2. Toggle the **Phone** icon **off**. Smart notifications and live sync are now suspended.
3. In your sensor settings, pair or connect to **AirHRM-DIY**. The handshake completes without contention.
4. Start your activity. HR streams from the bridge for the whole workout.
5. When finished, re-enable the **Phone** toggle. The watch reconnects to its companion app and uploads the activity.

Other brands (Polar, Wahoo, Suunto, Coros, …) expose equivalent controls under different names — *Phone connection*, *Smart features*, *Notifications off*. Verified on Garmin Forerunner 265; reports on other models welcome.

**One-time alternative.** Unpair the receiver from its companion app on the iPhone entirely. The ANCS link goes away, the collision can't happen, and the bridge pairs as a regular sensor with no per-activity steps. You lose live phone notifications and companion-app sync features on the watch; most sport watches still upload activities to the cloud via Wi-Fi or USB.

## Testing the BLE peripheral with LightBlue

[LightBlue](https://punchthrough.com/lightblue/) (free, by Punch Through) is a useful sanity check for the BLE side. With the bridge running on your iPhone, scan from LightBlue on a Mac or a second iOS device:

- Find the entry corresponding to the iPhone (often displayed under the GAP device name set in iOS Settings → General → About → Name).
- Properties to verify: `Local Name = AirHRM-DIY`, `Service UUIDs = 180D`, `Device Is Connectable = Yes`.
- Tap **Connect** → expand the **Heart Rate** service → tap **Heart Rate Measurement** (UUID `2A37`) → **Listen for Notifications**.
- You should see notified values like `0x00 5A` (= 90 BPM) arrive every ~5 seconds.

If LightBlue works, the peripheral is GATT-compliant and any standards-conforming central should be able to read from it.

## Known limitations

These are the findings collected during development and testing. Some are restrictions baked into iOS, some are receiver-specific.

- **iOS does not allow publishing the Device Information Service (`0x180A`)** from `CBPeripheralManager`. The `add` call fails with *"The specified UUID is not allowed for this operation"*. iOS exposes the DIS at the system level, but we cannot add manufacturer / model characteristics from app code. Some central firmwares that look for the DIS may interpret its absence in unexpected ways.
- **GAP Device Name (`0x2A00`) cannot be overridden** by the app. iOS automatically populates it with the iPhone's name from Settings. The `CBAdvertisementDataLocalNameKey` lets you set the *advertising* local name, but the post-connection GAP name remains the iPhone's name. Some central firmwares may treat the mismatch as suspicious.
- **iOS forces background advertising into "overflow" mode**, where the service UUID is moved into a special area readable only by iOS centrals scanning explicitly for it. Non-iOS centrals (LightBlue on Mac, most fitness watches) will not see the peripheral while the app is in the background. The app explicitly forces a clean `stopAdvertising` + `startAdvertising` cycle on every `didBecomeActive` notification to leave overflow mode, so it can be seen by all scanners in foreground.
- **The Heart Rate Measurement packet format used here is UINT8** (`[flags=0x00, bpm]`), so the maximum representable BPM is 255. Above that (which does not happen for humans) you would need to set the flags bit 0 to 1 and switch to UINT16.
- **Body Sensor Location value is cosmetic.** Set to *Chest* (`0x01`) by default; tested values (Chest, Ear Lobe) do not change receiver behavior.
- **Free Provisioning signs apps for only 7 days.** The app stops launching after that and must be re-installed via `⌘R` in Xcode, or auto-renewed by AltStore / SideStore.

## Compatibility (observed)

| Receiver | Status |
|---|---|
| LightBlue (iOS / macOS) | Verified |
| Garmin Forerunner 265 | Verified — requires the per-activity workaround above |
| Other Garmin / Polar / Wahoo / Suunto / Coros smartwatches | Likely OK with the same workaround — reports welcome |
| Cycling computers and gym equipment (non-smartwatch BLE HR centrals) | Likely OK without any workaround — reports welcome |

If you test with hardware not listed, please open an issue or PR with your findings.

## Background modes declared

- `workout-processing` — required for HealthKit live workout builder while the screen is off.
- `bluetooth-peripheral` — required to keep advertising and serving GATT in the background.

## Project structure

```
AirHRM-DIY/
├── AirHRM-DIY.xcodeproj/
├── AirHRM-DIY/
│   ├── AirHRM_DIYApp.swift           # SwiftUI entry + ContentView + Previews
│   ├── HeartRateBridge.swift         # Coordinator: orchestrates HK + BLE + audio
│   ├── HealthKitHRSource.swift       # HK auth, workout session, source classifier
│   ├── HRPeripheralAdvertiser.swift  # GATT, advertising, state restoration
│   ├── AudioRouteMonitor.swift       # AVAudioSession + foreground observer
│   ├── HRGatt.swift                  # GATT constants
│   ├── BridgeState.swift             # State enum
│   ├── HeartRateBridgeIntents.swift  # App Intents for Siri / Shortcuts
│   ├── AirHRM-DIY.entitlements
│   └── Info.plist
├── LICENSE
└── README.md
```

## Contributing

Pull requests welcome. Bug reports about the BLE side are most actionable when they include:

- iPhone model and iOS version.
- Receiver device and firmware version.
- Console.app logs from your iPhone, filtered by process `AirHRM-DIY`. The app emits structured `[ble] …`, `[bridge] …`, and `[hk-source] …` log lines that show what happens at each layer.

## License

MIT — see [LICENSE](LICENSE).

---

Built for personal use. Not affiliated with Apple, Garmin, Punch Through, or any other party mentioned.
