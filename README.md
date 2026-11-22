<p align="center"><img src="docs/icon.png" width="128" alt="Video Grid icon"></p>

# Video Grid

Video Grid plays multiple videos side by side in one Mac window. Each tile is its own VLC-powered player with its own playlist. You choose the grid (2×2, 3×2, 3×3, or your own pattern with bigger and smaller tiles), then drag videos in.

It handles anything VLC can play (MKV, MP4, MOV, AVI, WebM, TS, and many more), and videos never resize the window.

## Features

### Layouts
- **Pick a layout on launch:** 2×2, 3×2 (3 across, 2 down), 3×3, or a custom pattern.
- **Custom patterns:** separate rows with `/`. Each `O` is its own video, and a repeated letter makes one bigger video:

  | Pattern | Result |
  |---|---|
  | `XOO/XOO` | one tall video on the left, four small ones on the right |
  | `XXO/XXO/OOO` | one large video plus five small ones |
  | `XX/OO` | one wide video on top, two below |
  | `OOOO/OOOO/OOOO/OOOO` | 4×4, sixteen videos |

- **Switch layouts any time** from the Layout menu. Every tile keeps its videos.
- **Move any tile into the big slot** with ⌘1.
- **Maximize one tile** to fill the window with ⌘Return, and press Esc to go back. You choose what happens to the other videos' sound: they go quiet while it's maximized and get it back afterwards, or they keep playing. Set it in Settings or with *Playback → Silence Others When Maximized*.

### Windows
- **Several grid windows at once:** *File → New Grid Window* (⌘N) opens another window with its own layout and videos. Each new window steps down and to the right, so none hides another.
- **Open several windows at launch:** say how many in Settings, and give them all the same layout or a different layout each. With more than one display, each window gets its own display.
- **Resume where you left off:** Video Grid can reopen your windows with every playlist, each video at the point where you stopped it. Or it can start fresh every time.
- **Limit:** choose the most windows Video Grid will open at once.

### Resizing
- **Drag the line between two videos** to resize them. Only the tiles touching that line change size, so dragging a line in the top row leaves the bottom row alone.
- **⌥-drag** moves the whole line across every row or column.
- **Double-click a line** to even out the two sides. *Layout → Reset Tile Sizes* restores everything.

### Playback for each tile
- Play/pause, previous/next, and a seek bar.
- **Playlist** per tile: drop files or whole folders on it, reorder by dragging, and double-click to play. Tiles open on their playlist so you can fill them right away.
- **Drop to play:** dropping a video on a screen that's already playing switches to the new video right away. It's added to that screen's playlist too. (Settings can make drops join the end of the playlist instead.)
- **Choose the speakers.** By default sound goes wherever macOS sends it, so it moves to the TV when you AirPlay or cast. Pick speakers in Settings or *Playback → Sound Output* to keep Video Grid's sound on them. If they're disconnected, sound follows macOS until they're back.
- **Repeat** (off, all, or one) and **random**. Settings chooses what new screens start with, and *Playback → Every Screen in This Window* sets them for every screen at once.
- **A-B loop:** set two points and the tile loops between them. Click the button to type exact times.
- Volume and mute for each tile.

### Zoom and pan
- **Box zoom:** drag a rectangle over part of a video and that area fills the tile.
- **Other zoom controls:** pinch, scroll wheel, or ⌘-scroll to zoom toward the pointer.
- **Pan** by dragging or two-finger scrolling when zoomed in.
- **Reset** with a double-click or `0`. Zoom also resets whenever a screen starts a different video.
- **Zoom follows the tile's shape**, so a tall tile shows a tall slice of a wide video.

### File browser sidebar
- **Folder list:** a Finder-style list of your folders and videos. Start from Movies, Downloads, Desktop, an external drive, a connected server, or any folder you choose.
- **Starting folder:** set it in Settings, or choose *Start Here in New Windows* from the folder menu. If it's on a server that isn't connected, Video Grid tries to reconnect the server using the password saved in your keychain. If it's on a drive that's unplugged, or the server can't be reached, the browser opens your home folder instead.
- **Names or thumbnails:** show files as plain names, small thumbnails beside the names, or large thumbnails that fill the sidebar's width. Thumbnails work for every format, including MKV, AVI, and WebM, which Finder can't preview; they're grabbed with VLC and cached so they appear instantly next time.
- **Drag** videos onto any tile or its playlist, or **double-click** one to play it on the selected tile.
- **Right-click** a video for **Play on Screen ▸** or **Add to Screen's Playlist ▸**. While that menu is open, every tile shows its screen number in large type, and the one you point at lights up.
- **Placement:** put the sidebar on the left or the right, drag its edge to resize it, or hide it with ⌃⌘S or the title-bar button.

### Settings
*Video Grid → Settings…* (⌘,) has four pages:
- **General:** dark, light, or system appearance, and whether each video shows its number and file name.
- **Windows:** what happens at launch (resume where you left off, open your default windows, or ask for a layout), how many default windows to open, their layouts (the same for all or one each), and the most windows allowed at once.
- **Playback:** repeat, random, and mute for new screens (with a button to apply them to every open screen), what dropping a video on a screen does, whether a maximized video silences the others or they keep playing, and which speakers to play through.
- **File Browser:** names or thumbnails, left or right, the folder it starts in, and whether new windows show it.

### Whole-window keys
| Key | Action |
|---|---|
| **Space** | Play/pause the selected tile, or every tile if none is selected |
| **Return** | Play/pause every tile, whatever is selected |
| **Right Shift** (tap) | Mute/unmute every tile |
| **Esc** | Deselect the tile (or leave a maximized tile) |
| ⌥⌘P / ⌥⌘R / ⌥⌘S / ⌥⌘M | Play/pause all, restart all, stop all, mute all |
| ⌥⌘4 / ⌥⌘6 / ⌥⌘9 | Switch to 2×2 / 3×2 / 3×3 |
| ⇧⌘L | Custom layout |
| ⌘N | New grid window |
| ⌘O | Add files to the selected tile |
| ⌘, | Settings |

*Help → Video Grid Shortcuts* lists every key.

### Command line
Skip the layout picker and start playing right away:

```bash
"/Applications/Video Grid.app/Contents/MacOS/VideoGrid" --layout XOO/XOO --play a.mp4 b.mkv c.mov
```

## Requirements

- macOS 14 Sonoma or later
- A Mac with Apple silicon (M1 or later)

## Install

Download **Video Grid.dmg** from [Releases](https://github.com/labalicious/videogrid/releases) and open it. In the window that appears, drag **Video Grid** onto the **Applications** folder. It is signed and notarized by Apple, so it opens without security warnings.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`) and [VLC](https://www.videolan.org/vlc/) installed in `/Applications`. Full Xcode isn't needed.

```bash
./build.sh            # builds build/app.noindex/Video Grid.app
./build.sh install    # also copies it to ~/Applications
./build.sh dist       # signs, notarizes, and makes build/Video Grid.dmg
```

The build copies libVLC and its plugins out of VLC.app into the bundle, so the app runs on its own and later VLC updates can't break it. Re-run the build to pick up a newer libVLC. The build goes in a `.noindex` folder so Spotlight and Launchpad list only your installed copy.

`./build.sh dist` needs a **Developer ID Application** certificate (from developer.apple.com → Certificates) and saved notarization credentials:

```bash
xcrun notarytool store-credentials videogrid-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

`SIGN_ID=- ./build.sh dist` tests the signing and packaging steps without a certificate.

The app icon is drawn in code by `Tools/make-icon.swift`, and the installer window's background (the pink arrow to Applications) by `Tools/make-dmg-background.swift`. Run either with `swift Tools/<name>.swift` to regenerate `Resources/AppIcon.icns` or `Resources/dmg-background.tiff`. `./build.sh dist` asks Finder to arrange the installer window, so the first run asks permission for your terminal to control Finder.

## How it's built

The app is written in Swift and AppKit and talks to libVLC 3 through its C API. There's no Xcode project; `build.sh` compiles with `swiftc`.

| File | What it does |
|---|---|
| `Sources/Player.swift` | One libVLC player with its playlist, repeat, random, and A-B loop. Blocking libVLC calls run off the main thread. |
| `Sources/VideoView.swift` | Zoom and pan, done by cropping the source picture in VLC. |
| `Sources/TileView.swift`, `PlaylistView.swift` | Per-tile controls, the playlist, and the A-B popover. |
| `Sources/LayoutTree.swift` | Turns a pattern like `XOO/XOO` into nested splits so each dividing line drags on its own. |
| `Sources/GridWindowController.swift` | The grid, its draggable lines, the sidebar, and the window-wide keys. |
| `Sources/FileBrowserView.swift` | The file browser sidebar, its names/thumbnails views, and its Play on Screen menu. |
| `Sources/Thumbnails.swift` | Video thumbnails: Quick Look first, then a frame grabbed by libVLC, cached on disk. |
| `Sources/Settings.swift` | The preferences and the Settings window. |
| `Sources/Speakers.swift` | Choosing the speakers, and following them as they're connected and disconnected. |
| `Sources/Session.swift` | Saving and resuming windows and playlists, and finding (or reconnecting) the file browser's starting folder. |
| `Sources/LayoutPicker.swift`, `Support.swift` | The layout picker and pattern parsing. |
| `Sources/DebugHarness.swift` | Test-only (`DEBUG=1 ./build.sh`): drives the app and saves pictures of the window. |

## Credits

Made by Kevin Dimond. And built with ❤️ from Claude Code.

Playback is by [libVLC](https://www.videolan.org/vlc/libvlc.html) from VideoLAN. libVLC and its plugins are licensed under the LGPL/GPL, and their source code is available at [videolan.org](https://www.videolan.org).

## License

Video Grid is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE). You can use, share and change it, as long as versions you share stay under the same license.
