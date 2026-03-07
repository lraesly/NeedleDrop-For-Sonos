# NeedleDrop

**A macOS menu bar app for monitoring and controlling Sonos speakers**

*Version 2 — User Guide*

---

## Contents

1. [Key Features](#1-key-features)
2. [Installation](#2-installation)
3. [Getting Started](#3-getting-started)
4. [The Menu Bar Dropdown](#4-the-menu-bar-dropdown)
5. [Mini Player](#5-mini-player)
6. [Playback Controls & Keyboard Shortcuts](#6-playback-controls--keyboard-shortcuts)
7. [Zones & Speaker Grouping](#7-zones--speaker-grouping)
8. [Presets](#8-presets)
9. [Saving Tracks to Your Library](#9-saving-tracks-to-your-library)
10. [Scrobbling (Optional)](#10-scrobbling-optional)
11. [Settings Reference](#11-settings-reference)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Key Features

- **Menu bar integration** — Lives in your macOS menu bar. Click the icon to see what's playing, browse favorites, and control playback without switching apps.
- **Floating mini player** — An always-on-top window showing the current track with album art, transport controls, and volume. Available in compact or large sizes with an optional transparent overlay mode.
- **Track change banners** — Brief notification banners appear in the top-right corner when a new song starts.
- **Full album art view** — Click any album art to see it at full resolution in a floating window.
- **Zone management** — Switch between Sonos zones, group and ungroup speakers, and set per-speaker volumes.
- **Presets** — Save your favorite combinations of station + speakers + volume as one-click presets. Supports multiple homes.
- **Favorites** — Browse and play your Sonos favorites directly from the menu bar.
- **Library integration** — Save the currently playing track to your Spotify or Apple Music library with one click.
- **TV/HDMI audio support** — When your Sonos is playing TV audio, NeedleDrop adapts its display to show zone info and provides mute control instead of track skip.
- **Global keyboard shortcuts** — Control playback, volume, and track skip from anywhere on your Mac.
- **Launch at login** — Optionally start NeedleDrop automatically when you log in.
- **Last.fm scrobbling (optional)** — Requires a separate NeedleDrop Scrobbler server running on your network. Not included in this distribution. See the [Scrobbling](#10-scrobbling-optional) section for details.

---

## 2. Installation

### Requirements

- macOS 13 (Ventura) or later
- Sonos speakers on the same local network as your Mac

### Steps

1. **Unzip** the downloaded `.zip` file. You should see **NeedleDrop.app**.
2. **Drag NeedleDrop.app** into your `/Applications` folder (or wherever you keep apps).
3. **Double-click** NeedleDrop to launch it. A small music-note icon will appear in your menu bar.

> **First launch:** macOS may show a dialog saying the app is from an identified developer. Click **Open** to proceed. The app is signed and notarized with Apple.

> **Tip:** To have NeedleDrop start automatically when you log in, open Settings (gear icon in the dropdown) and enable **Launch at login**.

---

## 3. Getting Started

1. **Launch NeedleDrop.** The app icon appears in your menu bar (top-right of your screen).
2. **Wait for speaker discovery.** NeedleDrop automatically discovers Sonos speakers on your local network. The zone pill (top-left of the dropdown) shows an orange dot while searching and turns green once connected.
3. **Name your home.** On first connection, NeedleDrop asks you to name this Sonos system (e.g., "Home" or "Office"). This helps organize presets if you use Sonos in multiple locations. You can skip this step.
4. **Start playing music** on any Sonos speaker using the Sonos app, AirPlay, or by selecting a favorite from the music menu (**♪ ▾** button).
5. **NeedleDrop displays what's playing** with album art, track info, and playback controls.

---

## 4. The Menu Bar Dropdown

Click the NeedleDrop icon in your menu bar to open the dropdown. It has three areas:

### Header

- **Zone pill** (left) — Shows the active zone name and connection status. Click to switch zones or group speakers.
- **Music menu** (right, **♪ ▾**) — Browse favorites, activate presets, or create new presets.

### Main Content

When connected and music is playing, you see:

- Album art (click to view full size)
- Track title, artist, and album
- Transport controls: previous, play/pause, next
- Heart button to save the track to Spotify or Apple Music
- Volume slider with mute button
- Progress bar

When nothing is playing, you see "Nothing playing" with a music note icon. If speakers are still being discovered, you see a spinner and "Searching…"

### Footer

| Button | Description |
|--------|-------------|
| Picture-in-picture icon | Toggle the floating mini player window on/off |
| Bell icon | Toggle track-change banner notifications on/off |
| Gear icon | Open settings (speaker settings, scrobbling, library services) |
| NeedleDrop v2 | App version (informational) |
| Quit | Quit the app |

---

## 5. Mini Player

The mini player is a floating, always-on-top window that shows what's currently playing. It never steals focus from other apps.

### Showing and Hiding

- Click the **picture-in-picture icon** in the dropdown footer, or
- Enable **Show on launch** in settings to have it appear automatically when NeedleDrop starts.

### Moving the Window

Drag the title bar area at the top of the mini player to reposition it anywhere on your screen. NeedleDrop remembers the position.

### Size Options

Choose between two sizes in Settings > Mini Player Appearance:

| Size | Dimensions | Album Art | Best For |
|------|-----------|-----------|----------|
| **Compact** | 300 × 120 px | 56 × 56 px | Minimal footprint, quick glance |
| **Large** | 400 × 320 px | 200 × 200 px | Prominent display with large album art |

### Transparent Overlay Mode

When **Transparent overlay** is enabled (the default):

- The mini player is nearly invisible when you're not interacting with it (content at ~12% opacity).
- **Hover your cursor** over the window to reveal it with a dark translucent backdrop and white text.
- **When a new song starts**, the player briefly reveals itself for 4 seconds, then fades back.

When transparent mode is **off**, the mini player uses a solid system-material background and is always fully visible.

### Mini Player Controls

The mini player includes the same controls as the main dropdown:

- Album art (click to enlarge)
- Track info (title, artist, album)
- Previous / Play-Pause / Next buttons
- Save-to-library button (heart icon)
- Volume slider with mute
- Progress bar (compact shows bar only; large shows timestamps)

---

## 6. Playback Controls & Keyboard Shortcuts

### On-Screen Controls

Transport buttons and the volume slider are available in both the menu bar dropdown and the mini player.

### Global Keyboard Shortcuts

These work from anywhere on your Mac, even when NeedleDrop isn't focused:

| Key | Action |
|-----|--------|
| **Space** | Play / Pause |
| **Left Arrow** | Previous track |
| **Right Arrow** | Next track |
| **Up Arrow** | Volume up (+5%) |
| **Down Arrow** | Volume down (-5%) |

> **Note:** Keyboard shortcuts are temporarily disabled when a text field has focus (e.g., while editing a preset name).

### TV / HDMI Audio

When your Sonos is receiving audio from a TV via HDMI (e.g., Sonos Beam or Arc), NeedleDrop adapts:

- Shows a TV icon instead of album art
- Displays the zone name and speaker count
- Previous/Next buttons are hidden
- Play/Pause acts as mute/unmute

---

## 7. Zones & Speaker Grouping

### Switching Zones

Click the **zone pill** (top-left of the dropdown) to see all available Sonos zones. Click a zone to make it the active one. A music-note icon indicates which zone is currently playing audio.

### Default Zone

In Settings, you can set a **Default Zone**:

- **Auto (follow active)** — NeedleDrop automatically switches to whichever zone starts playing. This is the default.
- **A specific zone** — NeedleDrop always shows this zone, even if another one is playing.

### Grouping Speakers

1. Click the **zone pill** to open the zone list.
2. Click **Group Speakers…** at the bottom.
3. Check the speakers you want to group with the primary speaker. The primary (coordinator) is always checked and cannot be unchecked.
4. Adjust per-speaker volume using the sliders that appear below each checked speaker.
5. Click **Done** to apply the changes.

---

## 8. Presets

Presets let you save a combination of **station + speakers + volume** and recall it with one click.

### Creating a Preset

There are two ways to create a preset:

**From what's playing:**

1. While music is playing, click the **music menu** (**♪ ▾**).
2. Select **Save What's Playing…**
3. The preset editor opens, pre-filled with the current station, active speakers, and volume.
4. Give it a name and click **Create**.

**From scratch:**

1. Click the **music menu** and select **New Preset…**
2. Enter a name, pick a station from your Sonos favorites, select rooms, and optionally set a volume.
3. Click **Create**.

### Using a Preset

Click the **music menu** (**♪ ▾**) and select a preset from the **Presets** section. NeedleDrop will group the specified speakers, set the volume (if configured), and start playing the station.

### Managing Presets

Click the **music menu** > **Manage Presets…** to view, edit, or delete presets.

> **Multi-home support:** If you use Sonos in multiple locations (e.g., home and office), presets are automatically filtered to show only those for your current network.

---

## 9. Saving Tracks to Your Library

NeedleDrop can save the currently playing track to your **Spotify** or **Apple Music** library.

### Setup

1. Open the dropdown and click the **gear icon** to enter settings.
2. Go to the **Services** tab.
3. **Spotify:** Enter your Spotify Client ID and click **Connect**. You'll be prompted to authorize in your browser.
4. **Apple Music:** Click **Connect**. macOS will ask for permission to access Apple Music. If you previously denied access, click **Open Settings** to grant it in System Settings > Privacy & Security > Media & Apple Music.

> **Note:** Only one library service can be active at a time. Connecting one will disconnect the other.

### Saving a Track

When a library service is connected, a **heart icon** appears next to the transport controls. Click it to save the current track. A filled red heart means the track has already been saved this session.

---

## 10. Scrobbling (Optional)

NeedleDrop supports **Last.fm scrobbling** through a separate companion server called the **NeedleDrop Scrobbler**. The scrobbler is **not included** in this distribution — it runs as a separate service on your network.

### How It Works

- NeedleDrop tracks how long you listen to each song locally.
- If a NeedleDrop Scrobbler server is running on your network, NeedleDrop discovers it automatically via Bonjour.
- The scrobbler server handles the actual Last.fm API communication.
- A **green checkmark** appears next to the track title when a song has been scrobbled. This badge only appears when the scrobbler server is connected.

### Scrobbler Settings

In the dropdown settings, go to the **Scrobbling** tab:

- **Discover** — Searches your local network for a running scrobbler.
- **Check** — Tests the connection to the scrobbler.
- **Disconnect** — Stops using the scrobbler.
- **Filter rules** — When connected, you can set a minimum track duration and add artist/title patterns to exclude from scrobbling (useful for filtering ads or station breaks).

> **Without the scrobbler server:** NeedleDrop works perfectly fine. Scrobbling is entirely optional. All other features (playback control, presets, library saving, etc.) work independently.

---

## 11. Settings Reference

Open settings by clicking the **gear icon** in the dropdown footer. There are three tabs:

### Speaker Tab

| Setting | Description | Default |
|---------|-------------|---------|
| Launch at login | Start NeedleDrop automatically when you log in to macOS | Off |
| Show on launch | Open the mini player window when NeedleDrop starts | Off |
| Transparent overlay | Mini player uses a transparent style that reveals on hover | On |
| Size (Compact / Large) | Mini player window size | Compact |
| Default Zone | Which zone to follow: Auto or a specific zone | Auto |
| Speakers | Read-only list of discovered speakers with IP addresses | — |

### Scrobbling Tab

| Setting | Description |
|---------|-------------|
| Connection status | Shows whether a scrobbler server is found on the network |
| Discover / Check / Disconnect | Manage scrobbler connection |
| Min duration | Minimum track length (seconds) before scrobbling. Default: 90 |
| Filter rules | Artist/Title patterns to exclude from scrobbling |

### Services Tab

| Setting | Description |
|---------|-------------|
| Spotify | Connect with a Spotify Client ID to save tracks to your Spotify library |
| Apple Music | Connect to save tracks to your Apple Music library (requires macOS permission) |

---

## 12. Troubleshooting

### No speakers found

- Make sure your Mac and Sonos speakers are on the same Wi-Fi network.
- Check that your firewall isn't blocking UPnP/SSDP discovery (UDP port 1900).
- Try quitting and relaunching NeedleDrop.

### Menu bar icon is grayed out

This means NeedleDrop hasn't found any speakers yet. It will keep searching. Check your network connection.

### Mini player is invisible

If transparent overlay mode is on, the mini player may be nearly invisible when nothing is playing. Hover your cursor over where you placed it, or toggle transparent mode off in settings to make it always visible.

### Keyboard shortcuts not working

NeedleDrop's global keyboard shortcuts (Space, arrows) require Accessibility permission. If prompted, grant access in System Settings > Privacy & Security > Accessibility.

### Can't save tracks to library

- **Spotify:** Make sure your Client ID is correct and you've completed the OAuth authorization in your browser.
- **Apple Music:** Check that NeedleDrop has Media & Apple Music permission in System Settings > Privacy & Security.
- Only one service can be active at a time.

### Scrobbler not connecting

The NeedleDrop Scrobbler is a separate server application. Make sure it's running on the same network and advertising via Bonjour (`_needledrop._tcp`).

---

*NeedleDrop v2 — Built with SwiftUI for macOS*
