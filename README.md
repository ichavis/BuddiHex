# BuddiHex Rotator v1.7 and Raspberry Pi bridge

Use the Pi as the single connection to the ESP8266. SmartSDR connects to the Pi using Hamlib rotctld. BuddiHex for Mac uses the same TCP port with a BuddiHex connection that preserves the ESP8266's bearing, direction, fault and calibration feedback.

## Install on Raspberry Pi OS

1. Copy the `Pi` folder to the Raspberry Pi and open a terminal in that folder.
2. Edit `buddihex-bridge.conf`. Set `CONTROLLER_IP` to your ESP8266's IPv4 address and `LISTEN_IP` to the Pi's LAN IPv4 address. A DHCP reservation for the Pi keeps the address stable. The supplied loopback address limits the service to the Pi until you edit it.
3. Disable any Node-RED rotator flow or direct connection to the ESP8266 while using the bridge. On your home network use the Pi's LAN address. For off-site access, reach the Pi over a private VPN and use that address or a VPN route to the Pi's LAN address.

Run from the `Pi` folder:

```sh
sudo install -d /opt/buddihex
sudo install -m 644 buddihex_bridge.py /opt/buddihex/
sudo install -m 644 buddihex-bridge.conf /etc/default/buddihex-bridge
sudo install -m 644 buddihex-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now buddihex-bridge
sudo systemctl status buddihex-bridge --no-pager
```

To change the configuration after installation, edit `/etc/default/buddihex-bridge`, then run `sudo systemctl restart buddihex-bridge`. View service output with `journalctl -u buddihex-bridge -n 30 --no-pager`. The bridge uses standard Python 3 libraries. It accepts TCP on 4533 by default, sends UDP to the ESP8266 on 4210, and listens for its replies on UDP 4211.

## Connect both Mac apps

- **BuddiHex v1.7** — Open the Apple Silicon or Universal app. In Settings, enter the Pi hostname or IP and TCP port 4533 under Controller. Save and click Connect. Leave the Pi hostname blank to switch back to direct ESP8266 UDP. The optional local Hamlib server is unnecessary when SmartSDR connects to the Pi.
- **SmartSDR for Mac** — In Settings → Rotator, select Hamlib rotctld. Enter the Pi's address and port 4533. Use azimuth range 0–360° and leave elevation off. Open View → Rotator, connect, and check that the bearing matches BuddiHex.
- Before relying on automatic turning, check a short move and STOP with both apps displaying the same live bearing. Use one app at a time to issue movement commands. The ESP8266 firmware controls travel routing and north calibration.

A read-only check from a Mac terminal:

```sh
printf 'p\nq\n' | nc -w 3 PI_ADDRESS 4533
```

Expect azimuth and elevation on separate lines. Elevation is zero. `RPRT -5` means the bridge lacks fresh, fault-free position feedback. Movement and stop acknowledgements confirm that the bridge submitted a UDP command. Use current rotor feedback to verify the motor's response.

## Build and verification

Mac source is in `Mac`. Run `bash build.sh` there with Xcode Command Line Tools to build Universal and Apple Silicon versions. Existing station and controller settings are retained. See `Mac/README-v1.6.md` for existing app features and direct controller setup.
