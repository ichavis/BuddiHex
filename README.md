# BuddiHex Rotator

A macOS app and Raspberry Pi service for the ESP8266 BuddiHex R4 antenna rotator. The Mac app shows live bearing and movement, supports manual and preset headings, computes bearings from QRZ and DXCC lookups, and provides STOP and north calibration.

| Component | Location | Connection |
| --- | --- | --- |
| BuddiHex for Mac | [Mac](Mac/) | Direct ESP8266 UDP or TCP to the Pi |
| Linux bridge | [Pi](Pi/) | Serves BuddiHex and Hamlib clients over TCP and exchanges commands and feedback with the ESP8266 over UDP |
| SmartSDR for Mac | Settings → Rotator | Hamlib rotctld on the Pi, or the Mac app's optional local Hamlib server |

The Pi mode uses TCP **4533**, sends UDP commands to the ESP8266 on **4210**, and receives feedback on UDP **4211**. The controller firmware determines travel routing. Use one app at a time to send movement commands.

[Download the BuddiHex v1.7 user guide (PDF)](docs/BuddiHex-Rotator-v1.7-User-Guide.pdf)

## Build and run the Mac app

Requires macOS 13 or later. To build from source, install the Apple Command Line Tools and run:

```sh
cd Mac
./build.sh
```

The script creates locally signed builds under `Mac/build/Apple-Silicon/` and `Mac/build/Universal/`. The Universal build supports Intel and Apple Silicon. The v1.7 release bundle also contains both builds.

In the app's gear menu, set your station location with a Maidenhead grid or latitude and longitude. Enter QRZ credentials for lookup or use the DXCC country-list fallback. The app keeps the QRZ password in macOS Keychain.

- **Pi bridge:** Enter the Pi's hostname or IP and TCP port **4533** under Controller. Save and click **Connect**.
- **Direct UDP:** Clear the Pi hostname. Enter your ESP8266's numeric IPv4 address and the command and reply ports. For SmartSDR on the same Mac, enable **Hamlib rotctld server** in BuddiHex and point SmartSDR to `127.0.0.1:4533`. BuddiHex must be open and connected.

## Install the Linux bridge

Requires Raspberry Pi OS or another systemd-based Linux distribution with Python 3. The bridge uses the standard library.

1. Copy or clone the repository onto the Pi, then enter the `Pi` directory.
2. Copy the example configuration to a local file. Set `CONTROLLER_IP` to the ESP8266's LAN IPv4 address and `LISTEN_IP` to the Pi's LAN IPv4 address. The example uses `127.0.0.1` for local-only testing.
3. Disable any Node-RED rotator flow that is using UDP 4211 on this Pi or issuing commands directly to the same ESP8266.

```sh
cp buddihex-bridge.conf buddihex-bridge.local.conf
nano buddihex-bridge.local.conf
sudo install -d /opt/buddihex
sudo install -m 644 buddihex_bridge.py /opt/buddihex/
sudo install -m 644 buddihex-bridge.local.conf /etc/default/buddihex-bridge
sudo install -m 644 buddihex-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now buddihex-bridge
sudo systemctl status buddihex-bridge --no-pager
```

Change installed settings in `/etc/default/buddihex-bridge`, then run `sudo systemctl restart buddihex-bridge`.

In SmartSDR, choose **Hamlib rotctld** under **Settings → Rotator**, enter the Pi's LAN address and port **4533**, select **0–360°**, and leave elevation off. Open **View → Rotator**, connect, and verify the bearing before testing movement.

## Connect over Tailscale

Install [Tailscale for Linux](https://tailscale.com/docs/install/linux) on the bridge Pi and [Tailscale for macOS](https://tailscale.com/download/mac) on the Mac. Join both to the same tailnet. Only the Mac and Pi need Tailscale. The Pi continues to reach the ESP8266 on the station LAN.

For direct tailnet access:

1. On the Pi, run `tailscale ip -4` to get its Tailscale IPv4 address.
2. Set `LISTEN_IP` in `/etc/default/buddihex-bridge` to that address, leave `CONTROLLER_IP` set to the ESP8266 LAN address, and restart the bridge.
3. Point BuddiHex and SmartSDR to the Pi's Tailscale IP or [MagicDNS name](https://tailscale.com/docs/features/magicdns) on TCP **4533**. Make sure your tailnet policy permits the Mac to reach that port. Run the read-only test below before sending a movement command.

Binding directly to the Tailscale IP makes that listener reachable on the tailnet. If you already have an [approved Tailscale subnet route](https://tailscale.com/docs/features/subnet-routers/how-to/setup) to the station LAN, you can keep the existing LAN bind and use the Pi's LAN address both at home and remotely. Avoid forwarding TCP 4533 from the public internet. The rotator bridge does not authenticate clients itself.

## Troubleshooting

From the Mac, substitute the LAN or Tailscale address actually configured on the Pi:

```sh
printf 'p\nq\n' | nc -w 3 PI_ADDRESS 4533
```

- **Two numbers:** TCP reached the bridge and it returned azimuth and elevation. Elevation is zero.
- **`RPRT -5`:** TCP is working. Check the ESP8266 address and UDP feedback.
- **Connection refused or timed out:** On the Pi, run `sudo ss -ltnp 'sport = :4533'`. Compare the address displayed there with the address used by the Mac. For Tailscale, also check that both devices are connected and that policy permits the port.
- **Service restarts with `Address already in use`:** Check `sudo journalctl -u buddihex-bridge -b -n 40 --no-pager`. If the traceback points to the UDP bind, check `sudo ss -lunp 'sport = :4211'` for a Node-RED flow or another owner. If it points to the TCP bind, check port 4533.
