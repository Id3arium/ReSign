# ReSign

Keep your sideloaded iOS apps from expiring.

ReSign is a macOS menu bar app that watches your Xcode projects and automatically rebuilds and installs them to your connected iPhone before their signatures expire.

## How it works

- Scans a folder for Xcode projects
- Tracks when each app was last signed
- Rebuilds and reinstalls automatically when expiry is approaching
- Lives in your menu bar — green means all good, red means something needs attention

## Requirements

- macOS 14+
- Xcode with a valid Apple Developer account
- iPhone connected via USB

## Usage

1. Open ReSign from your Applications folder
2. In the menu bar, click the gear icon → set your projects folder and select your device
3. ReSign will handle the rest

To trigger a manual rebuild, click **Rebuild** next to any project.

## Build from source

```bash
./build.sh
cp -R build/ReSign.app /Applications/
```
