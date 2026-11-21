# Battery view: design (20 Nov 2026)

Status: agreed in chat, not committed. Build after the weekly limit resets (Sun 22 Nov).

## Why
Show everything about the battery in the app itself (like iStat Menus / macOS Battery settings), and answer the question macOS doesn't: how long does one battery charge last me **while the Mac is awake** (not only with the screen on), and how much goes to sleep.

## Toggle button (main window top row, between "Sleep only" and "Start at login")
- A battery icon that fills with the charge, % inside, ⚡ while charging, red below 20 %.
- Next to it: "0:19 until full" / "4:35 left" / "Fully charged" / "Calculating…".
- Click toggles the Battery view; pressed (highlighted) while the view is on. Tooltip "Show / Hide battery details".
- Updates at the "Update every" interval, visible in all time frames including Live.
- Battery view and "Sleep only" switch each other off; both are off when the window opens.
- Hidden on Macs without a battery.

## Battery view
The selected time frame has NO effect on this view; the time frame buttons are hidden while it is on.

1. **Two cards side by side, always the same width and height** (the user wants symmetry; in a very narrow window they stack, still equal width). The button already shows %, so card 1 doesn't repeat it as a separate row.
   - **Card 1, state card**, changes with the state:
     - On battery: header "On battery for 2:55 · since 08:10 at 92 %"; big "68 % · 4:35 left"; rows: Awake / asleep, Drawing now (W · mA), Average while awake (W).
     - Charging: header "Charging for 0:40 · since 18:20 at 20 %"; big "92 % · full in 0:19"; rows: Charging with (W · mA), Charger (name · max W), Mac uses now (W).
     - Fully charged on the charger: header "On charger since …"; big "100 % · Fully charged"; rows: Charger, Mac uses now.
   - **Card 2, Battery health**: big "100 % · Normal" (macOS's status); rows: Capacity now / when new (mAh), Cycles, Temperature, Voltage.
2. **Per charge** chart, one bar group per charge (unplugged → plugged in again): charge used %, awake time, asleep time. Labels with date/time span; the current charge is shown as "running". Tooltip per bar: start/end, charge from–to, Wh used, average W while awake.
3. Charges shown: all charges macOS's battery log still has (about 10 days), newest on the right; scroll left for older ones.

## Rules and defaults
- Unplugs shorter than 10 min or using < 3 % are not a separate charge.
- Time estimate: macOS's own value for now, **behind its own interface** (`BatteryTimeEstimator` or similar) so the user's own, more dynamic calculation can replace it later without touching the view.
- All new texts through the central text layer (string catalog), each value with an explaining tooltip.
- Data: live values from the battery's IOKit record (AppleSmartBattery: CurrentCapacity, IsCharging, ExternalConnected, AvgTimeToFull/Empty, Voltage, Amperage, CycleCount, NominalChargeCapacity, DesignCapacity, Temperature to confirm, AdapterDetails). History from macOS's battery log (charge level, charger connected); awake/asleep from the existing sleep analysis. No new permissions; nothing leaves the Mac.

## Approaches considered
- One bar per day (like macOS) vs. **one bar per charge (chosen)**: per charge answers "how long does a charge last me awake".
- Checkbox vs. **battery icon button (chosen)**: shows state even when the view is off.

## Left to the builder
Exact layout and colors, chart library (Swift Charts), how charges are cut from the battery log, test plan (accuracy of awake/asleep per charge against the Sleep only numbers, Macs without battery, US/German formats, light/dark, smallest window).
