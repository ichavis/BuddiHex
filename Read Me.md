# BuddiHex Rotator for Apple Silicon — version 1.4

A native SwiftUI Mac app for the ESP8266 BuddiHex controller used by your R4 Node-RED flow. Requires an Apple Silicon Mac and macOS 13 or later. Node-RED is not required.

## Start here

1. Unzip **BuddiHex-Rotator-Mac-v1.4.zip** and move **BuddiHex Rotator.app** to Applications.
2. Stop or disable your Node-RED rotator flow. Use one controller application at a time.
3. Open the app. If macOS blocks this locally signed build, use System Settings → Privacy & Security → Open Anyway after the attempted launch. This build is locally signed; it is not Apple-notarized.
4. Open the gear button. Enter one controller IPv4 address per line (initially `192.168.0.36`). Verify the shared command port `4210`, and local reply port `4211`.
5. Set your antenna location by entering either a **4- or 6-character Maidenhead grid square** (for example FN31 or FN31PR), or latitude and longitude directly. A valid grid automatically fills the latitude/longitude of its center. Editing either coordinate clears the grid, so your direct coordinates take precedence. West and south are negative. Replace the example location before using QRZ bearings.
6. Enter your QRZ username and password, then Save. The password is stored in macOS Keychain; it is not included in the app or diagnostic logs. Location data requires the appropriate QRZ XML subscription.
7. Choose an IP from the main window’s controller menu, then choose **Connect**. Allow local-network access if macOS asks. Wait for **CONTROLLER ONLINE** and a current bearing before using movement controls.

Automatic connection is off by default. Enable **Connect automatically when app launches** under Controller in Settings and Save to connect on future launches. Automatic connection polls the current bearing; it never sends a movement target. The app never moves the rotor automatically on launch. Your Mac must be able to reach the ESP8266 directly, on the same network or through a configured network route. The app does not proxy commands through your Node-RED Pi.

## Version 1.4 controller selection

Your existing controller address appears in the list after upgrading. Open Settings to add or remove addresses and click **Save**. The app remembers the selected IP across launches and uses it for automatic connection. If you remove the selected address, the app selects the first address in the saved list. Disconnect before using the main-window menu to switch controllers, then click **Connect**.

## Version 1.3 status update

After any manual, preset, or QRZ target, the status follows fresh controller feedback: moving CW/CCW with current and target bearings, target reached when stopped within 5°, stopped short of target, fault/stuck, or offline. STOP remains pending until the controller reports stopped. Bearing-only AZ replies do not confirm movement or arrival. Targets, QRZ lookup, grid settings, and calibration remain separate. This matches the Node-RED status-display change; the app continues to communicate directly with the controller.

## Controls

- **Station grid square:** accepts 4 or 6 characters, normalizes to uppercase, and fills coordinates as soon as a valid grid is entered. Incomplete or invalid grids cannot be saved. Clearing the grid retains the displayed coordinates. Existing settings from earlier versions are preserved.
- **Settings…:** use BuddiHex Rotator → Settings… or **Command-comma**. The gear button opens the same settings screen.

- **Manual target / GO:** enter a whole-number bearing from 0 to 360.
- **Direction presets:** send their displayed bearings immediately.
- **STOP:** sends the R4 stop command. Keyboard shortcut: **Command-period**.
- **QRZ Look up:** calculates a station's bearing and distance. Lookup does not move the antenna. Choose **Rotate to…** and confirm to move.
- **Compass and map:** fixed size; QRZ details cannot shrink the map. Details collapse after two stopped replies within 5° of the QRZ target. Use Details to reopen them.
- **Refresh:** requests the current bearing. Shortcut: **Command-R**.
- **Set north:** the antenna must already physically point TRUE NORTH. This sets its current location as the north reference; it does not drive it north. The app sends STOP, waits for two stable stopped replies, sends `CAL_DECL`, then checks that the controller reports north. Movement commands are disabled during that sequence.
- **Log:** shows timestamped commands and replies. Save log exports a plain text diagnostic file.
- **Disconnect / quit:** sends STOP before closing the connection. UDP provides no delivery guarantee; look at controller feedback to confirm stopped state.

## Controller compatibility

Movement uses the exact R4 command format: `<AZIMUTH>123`. STOP uses `<PST><STOP>`, polling uses `GET_BEARING`, and calibration uses `CAL_DECL`. The controller firmware chooses motor direction and travel routing; the app does not reverse wiring or add intermediate north waypoints. Replies are accepted only from the configured controller IPv4 address and command port.

This app cannot correct a previously incorrect physical north reference or firmware motor-direction fault. Its current, manual and QRZ bearings are separate values.

## Verification

- Controller list validation, upgrade from a single saved address, selected IP persistence, without connecting to a controller.
- Native arm64 compilation and local code-signature verification.
- Grid-center conversion, lowercase/whitespace normalization, incomplete/invalid grid rejection, direct-coordinate overrides, persistence, and migration from settings without a grid field.
- The v1.3 simulator tests cover automatic connection and verify that it sends no movement target and respects a manual disconnect.
- QRZ XML parsing, namespaces, escaped text, grid fallback, missing locations, true zero coordinates, and great-circle calculations using fixtures.
- In v1.3, a simulated controller on `127.0.0.1` verified real UDP polling, manual moves, QRZ moves, STOP, independent target values, arrival collapse, and stop-first north calibration.
- Tests did not contact or move the real controller, use a QRZ password, or verify a live QRZ subscription.

## Source and rebuilding

The **BuddiHex-Rotator-Mac-Source-v1.4** folder contains the complete Swift source, icon, app metadata, build script and simulator tests. Install Apple's Command Line Tools, then run `./build.sh`. The app is created in the source folder's `build` directory. Run `./test.sh --offline` for offline tests or `./test.sh` to include local UDP simulator tests. The v1.4 build environment blocked the simulator from binding a UDP socket.
