# NDI-Viewer

Menu bar app for checking the NDI sources on a stage. It shows a live gallery with host names and IPs, and you can click a tile for the full stream with stats and audio. The same gallery is served to phones on the network.

## Build & run

```sh
./scripts/build.sh            # needs Xcode, xcodegen, and the NDI SDK in /Library/NDI SDK for Apple
open build/NDI-Viewer.app
```

Click the menu bar icon to open the gallery. The popover's open-in-browser button (or right-click → Open in Browser) opens the same UI in a regular browser window on the Mac.
Right-click the icon for: Open in Browser, Copy Phone Link, Popover Size, Launch at Login, and Quit. Launch at Login is turned on the first time the app runs.
The web port is 8080 by default. If 8080 is taken, the app uses the next free port, up to 8090.

## How it works

- **Wake/sleep.** The NDI finder and receivers run only while someone is viewing: the popover, a detached window, or a phone tab that is visible and not on hold. When the last viewer leaves, receivers close after a 5 s grace period and the finder after 10 s.
- **One receiver per source.** Every viewer shares one NDI connection per source. Thumbnails use NDI's low-bandwidth stream; enlarged tiles, the full view and detached windows use full bandwidth.
- **Browser video.** Frames are sent as JPEG over WebSocket. A device gets a new frame only after it confirms the previous one, so slow phones get a lower frame rate instead of a backlog.
- **Browser viewers** (phones and Mac browser windows; only the popover is exempt). A hidden tab or locked phone pauses immediately. After the idle timeout (gallery 5 min, full view 3 min) the viewer goes on hold, and a tap resumes it. The host can hold any browser viewer from the Viewers panel. The number of remote full-quality streams is capped (default 2); beyond the cap, phones get preview quality.
- **Stages** are saved on the Mac in `~/Library/Application Support/NDIViewer`. A stage stores each source's name, host, IP and a still frame. While a stage is open, its IPs are added to NDI discovery so sources on other subnets are still found.
- **Layouts** (order, removed tiles, tile sizes, base size) are saved per device and per stage in the browser's localStorage. Each device can save several named layouts.

## Layout

```
NDIViewer/App      menu bar, popover (WKWebView), JS bridge
NDIViewer/Core     NDI finder, ReceiverHub (shared receivers, JPEG/pixel buffers), stages, settings
NDIViewer/Server   HTTP + WebSocket server, viewer sessions and hold/cap rules
NDIViewer/Native   detached window (AVSampleBufferDisplayLayer + AVAudioEngine)
NDIViewer/Web      the gallery UI (plain HTML/CSS/JS, no CDN, works offline)
```

Debug builds only: launch with `NDIVIEWER_ALL_REMOTE=1` to treat every client as remote, which lets you test idle hold and the cap from the Mac.
