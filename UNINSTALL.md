# Removing Mac Energy Monitor completely

Everything the app stores on the Mac (checked 18 Nov 2026, version 2.0):

| What | Where | Size | Notes |
|---|---|---|---|
| The app | `/Applications/Mac Energy Monitor.app` | ~2.5 MB | |
| Unpacked copies of macOS's power logs | `~/Library/Application Support/MacEnergyMonitor/PowerLogs` | ~150–300 MB | can be deleted any time; the app unpacks them again (versions up to 1.1.1 kept them in `~/Library/Caches/MacEnergyMonitor`) |
| Saved daily history + app-switch record | `~/Library/Application Support/MacEnergyMonitor` | < 1 MB | **your long-term history** — keep a copy if you may reinstall |
| Settings (view, filters, appearance …) | `~/Library/Preferences/local.mac-energy-monitor.plist` | 4 KB | |
| macOS's own cache for the app | `/var/folders/…/C/local.mac-energy-monitor` | small | created by macOS; removed by macOS over time |
| "Start at login" registration | System Settings → General → Login Items → Open at Login | — | switch **off** "Start at login" in the app *before* deleting it |

## Steps

1. In the app, switch **Start at login** off (window top row or menu bar panel).
2. Quit the app (menu bar panel → power button).
3. Delete the app and its files:

```bash
rm -rf "/Applications/Mac Energy Monitor.app" ~/Library/Caches/MacEnergyMonitor ~/Library/"Application Support"/MacEnergyMonitor ~/Library/Preferences/local.mac-energy-monitor.plist
```

The app never writes anywhere else: macOS's power logs in `/var/db/powerlog` are only read, never changed.
