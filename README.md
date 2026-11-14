# Mac Energy Monitor

A small native menu bar app for Apple silicon Macs that shows **how much power your Mac uses right now, and where the energy went** over the last hour, days or weeks, per app and per part of the hardware.

- **Menu bar:** the whole Mac's power draw in watts, updated every second (or every 2, 5 or 10 s).
- **Live view:** a 5-minute chart, a breakdown into display, CPU (your apps / macOS's own processes), GPU, memory, the rest of the chip and other hardware, plus a table of the apps and services using power right now.
- **History:** 1 hour, 24 hours, 3 days, 7 days, all, or any custom period. Energy (Wh), average power, screen-on time, the same hardware breakdown, and a sortable, filterable table of apps with energy, running time, CPU time and screen time.
- **Long-term history:** macOS keeps its power logs for only about 10 days. The app saves a small summary of every finished day, so its history goes back as far as the app has been running.
- **Start at login** (hidden, menu bar only), light/dark appearance, and it remembers your views and filters.

No admin rights, no network access, no tracking. Everything stays on your Mac.

![Live view: whole-Mac power, breakdown by hardware part, and the apps using power right now](docs/live.png)

<table>
<tr>
<td width="68%"><img src="docs/history.png" alt="History for 7 days: energy, average power, screen time and a table of apps"></td>
<td width="32%"><img src="docs/menubar.png" alt="Menu bar panel: power now, average power, live breakdown and top apps"></td>
</tr>
<tr>
<td align="center"><sub>History (here 7 days)</sub></td>
<td align="center"><sub>Menu bar panel</sub></td>
</tr>
</table>

## Requirements

- A Mac with **Apple silicon** (M1 or later)
- **macOS 14 Sonoma or later**

It was developed and tested on an M1 Pro with macOS 27. Other chips and macOS versions use the same data sources with fallbacks, but haven't been tested on real hardware yet. Reports are welcome (see below).

## Install

1. Download `Mac-Energy-Monitor.zip` from the [Releases](../../releases) page and unzip it.
2. Move **Mac Energy Monitor.app** to your **Applications** folder.
3. Open it. Because the app isn't notarized by Apple, macOS shows a warning the first time: **"Mac Energy Monitor" Not Opened. Apple could not verify "Mac Energy Monitor" is free of malware…** Click **Done** (not "Move to Trash"). Then allow it once:
   - Open **System Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to "Mac Energy Monitor" (available for about an hour after you tried to open the app).
   - Confirm with your login password and click **Open**.

   After that, it opens normally.

   Apple describes the steps in [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

Prefer not to run a downloaded app? Build it yourself (next section). The result is the same.

## Build from source

You need Apple's free Command Line Tools (`xcode-select --install`) or Xcode. No Xcode project is required.

```bash
git clone https://github.com/vankov1976/mac-energy-monitor.git
cd mac-energy-monitor
./build.sh
```

The app is written to `build/Mac Energy Monitor.app`. Move it to `/Applications`.

## Where the numbers come from

All data comes from what macOS already measures:

| What | Source |
|---|---|
| Whole Mac, live | The system management controller (SMC) power sensor |
| Display, live | SMC backlight power |
| CPU, GPU, memory, rest of the chip, live | The chip's energy counters (IOReport) |
| Apps, live | Per-process energy counters from macOS (`proc_pid_rusage`) |
| History | macOS's own power log (`/var/db/powerlog`, read-only) |

Some parts are **estimates**: for example "Other hardware" is what remains of the whole Mac after the chip and display, and history older than macOS's logs comes from the app's saved daily summaries. Click **"How these numbers are measured"** at the bottom of the window for the details.

## Uninstall

See [UNINSTALL.md](UNINSTALL.md) for every file the app creates and how to remove them. In short: switch off "Start at login" in the app first, then delete the app.

## Credits

The live chip readings on newer macOS versions use the method and counter IDs from [macmon](https://github.com/vladkens/macmon) by vladkens (MIT License). See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Support

Mac Energy Monitor is free and stays free for everyone. If it's useful to you and you'd like to say thanks, you can [buy me a coffee ☕](https://buymeacoffee.com/vankov1976). Completely optional, and much appreciated.

## Feedback

Found a bug, or tried it on another chip or macOS version? Please open an [issue](../../issues) and include your Mac model, chip and macOS version.

## License

[MIT](LICENSE)
