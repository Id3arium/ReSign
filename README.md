# ReSign

Keep your sideloaded iOS apps from expiring.

ReSign is a macOS menu bar app that watches your Xcode projects and automatically rebuilds and reinstalls them to your connected iPhone before their signatures expire.

## How it works

- Scans a folder for Xcode projects
- Tracks when each app was last signed and when the provisioning profile expires
- Rebuilds and reinstalls automatically when expiry is approaching (2 hours before)
- Checks on launch, every 2 hours, and whenever your Mac wakes from sleep
- Lives in your menu bar — green means all good, red means something needs attention

## Requirements

- macOS 14+
- Xcode with a valid Apple Developer account (free or paid)
- iPhone connected via USB or paired over Wi-Fi

## Usage

1. Open ReSign from your Applications folder
2. Click the menu bar icon → gear icon → set your **projects folder** and select your device
3. ReSign will handle the rest

ReSign scans one level deep inside the projects folder, looking for `ProjectName/ProjectName.xcodeproj`. To trigger a manual rebuild at any time, click **Rebuild** next to any project.

## Troubleshooting

**"Not signed in to Xcode"** — Open Xcode → Settings → Accounts and sign in with your Apple ID. ReSign will automatically retry any pending builds once it detects you're signed in.

**"No iPhone found"** — Make sure your iPhone is connected via USB and unlocked, or that Wi-Fi pairing is active in Xcode → Devices and Simulators. ReSign uses `devicectl` and requires macOS 14+.

**Project not appearing** — The folder must contain `ProjectName/ProjectName.xcodeproj` (the name of the subfolder and `.xcodeproj` must match). macOS-only or watchOS-only projects are excluded automatically.

## Build from source

```bash
./build.sh --install   # Release build, installs to /Applications and launches
```

For development iteration, plain `./build.sh` does a Debug build and runs from `./build/` without touching `/Applications`.

## License

MIT
