# Tapo Cameras — Omarchy Plugin

An [Omarchy](https://omarchy.org) plugin that adds a bar icon for quickly
viewing your TP-Link Tapo cameras. Click the icon to see your camera list,
click a camera to open its live RTSP stream in `mpv`.

This is a `bar-widget` plugin: a bar icon (`BarWidget.qml`) that opens a
floating panel (`Panel.qml`) listing the cameras from your config file.

## Requirements

- Omarchy with plugin support (`omarchy plugin` commands)
- [`mpv`](https://mpv.io) installed, used to play the RTSP stream
- Tapo cameras with RTSP enabled and a **camera account** configured
  (Tapo app → your camera → Advanced Settings → Camera Account). This is
  separate from your TP-Link cloud login — RTSP auth uses these
  credentials, not your cloud account.

## Install

```sh
omarchy plugin install https://github.com/ZestyBytes/omarchy-plugin-tapo
```

Or manually:

```sh
git clone https://github.com/ZestyBytes/omarchy-plugin-tapo \
  ~/.config/omarchy/plugins/io.github.zestybytes.tapo-cameras
```

Then validate it (if you're developing/editing locally):

```sh
omarchy plugin validate ~/.config/omarchy/plugins/io.github.zestybytes.tapo-cameras
```

## Configure your cameras

Copy the example config and fill in your cameras' IPs and camera-account
credentials:

```sh
cp ~/.config/omarchy/plugins/io.github.zestybytes.tapo-cameras/cameras.json.example \
   ~/.config/omarchy/plugins/io.github.zestybytes.tapo-cameras/cameras.json
```

`cameras.json`:

```json
[
  {
    "name": "Front Door",
    "ip": "192.168.1.50",
    "username": "camuser",
    "password": "campass",
    "port": 554,
    "stream": "stream1"
  }
]
```

- `stream1` = HD stream, `stream2` = SD stream (lower bandwidth).
- The panel watches this file, so editing it live-reloads the camera list.
- **This file holds camera credentials in plaintext.** It's already
  git-ignored by this repo; keep its permissions locked down
  (`chmod 600 cameras.json`) since anyone with read access to it gets RTSP
  access to your cameras.

## How it works

- `BarWidget.qml` — bar icon, toggles the panel.
- `Panel.qml` — floating panel, lists cameras from `cameras.json` and
  launches `mpv` with a low-latency RTSP URL when one is clicked.
- `CameraModel.js` — parses `cameras.json` and builds the
  `rtsp://user:pass@ip:port/streamN` URL for each camera.

## Roadmap / ideas

- Live thumbnail snapshots instead of a plain list
- PTZ controls (pan/tilt/zoom) for supported models
- Multi-camera grid view in one panel

## License

MIT
