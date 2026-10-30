# Switchyard

One app for the OpenWrt ASUS (RT-AX1800S, running as an RT-AX57M) and the TP-Link Archer AX1500.

**ASUS (OpenWrt):** live speed and upstream signal, devices (kick off Wi-Fi, cut or restore internet), ad blocking on/off, your own blocked and allowed sites, the WARP tunnel, Wi-Fi names/passwords/channels, guest network, nearby-network scan, router lights and their schedule, drop logging, connection test, logs, package update check, reboot.

**TP-Link:** status, CPU and memory, devices, Wi-Fi bands and guest networks on/off, names and passwords, lights (if the firmware has that page), reboot.

Keystone has the same ASUS controls, through the bridge, so they work away from home.

## One-time router setup (ASUS)

SSH into the router and run:

```
wget -qO- https://raw.githubusercontent.com/soum91/switchyard/main/router/install.sh | sh
```

It installs a small rpcd plugin (`router/switchyard`, ucode) and its permissions file. Then in the app, sign in with the root password once. The router creates a separate `switchyard` login that can only use the plugin; the root password isn't stored.

## Builds

Every push to `main` builds an unsigned IPA (`Switchyard-<version>-build-<n>.ipa`) and publishes a release with a changelog. Sideloading source: `https://raw.githubusercontent.com/soum91/switchyard/source/source.json`
