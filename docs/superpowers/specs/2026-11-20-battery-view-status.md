# Battery view: build status (20 Nov 2026, late evening)

Nothing committed. Design: `2026-11-20-battery-view-design.md` (the user changed several details since; this file is current).

## Done and checked with the user (test build, real data)
- Battery button just left of "Start at login": green icon (red < 20 %), % inside, ⚡ while charging,
  time left / until full = macOS's own estimate (IOPSGetTimeRemainingEstimate / time to full); "Calculating…" for
  90 s after plugging in or out. Toggles the view; time frame buttons and Sleep only hidden in the battery view;
  footer (How these numbers are measured, version, coffee) stays, with its own battery explanation.
- Two equal cards: state card (on battery / charging / on charger; since when at which %; awake (display on),
  asleep, switched off, drawing now / charging with / charger / Mac uses now) and battery health (macOS rating).
  Live values every second from the SMC (PSTR whole Mac, PDTR charger input); awake/asleep computed live.
- Per-charge chart: one charge per unplugging (tiny ones < 10 min and < 3 % dropped), newest on the LEFT, up to 30,
  scrolls sideways, fixed value scales on both sides (placed from the charts' real plot areas), "% used" in blue
  under the green bars, under the hour bars: range / "x awake (y display on)" / "z asleep · w switched off";
  charges before macOS's sleep log: "x on battery". Hover tooltip per charge column (chart redrawn only when data changes).
- Switched-off time (cold boot in a log gap, or a gap > 30 min not asleep) is not counted as awake.
- Smallest window (940 × 522): everything fits, scale labels thin out.
- All texts of the feature in `Sources/BatteryTexts.swift` (String(localized:)).
- All checks (`tools/checks.sh`) passed after the first build; rerun after the final changes (see below).

## Still to do
1. Dark mode look; MacBook Air (US format, test build in /tmp/mem3; the Air has no Mac Energy Monitor test data issues expected).
2. README text + screenshot, release notes, at the next release (only when the user asks).
3. Later: the user's own time-left calculation as a second `BatteryTimeEstimator`.

## Added 21 Nov
- Menu bar: battery after the watts (monochrome icon with %, our time; dots while calculating), "In menu bar"
  checkbox in the panel; panel 384 pt wide, no arrow, closes on clicks outside (also on the menu bar).
- Own time estimate: energy ÷ 5-min average (filled from the log at start, InstantAmperage), shown value every 10 s;
  time until full along this Mac's learned charging curve (median power per level from its log).
- Battery read every second only the needed keys; BatteryData (capacities) every 30 s.
- Automated checks: `--chargecheck` (in tools/checks.sh): charge times add up, no overlaps, estimate math, curve.
- Fixed: on the MacBook Air (macOS 27.3 beta) macOS's sleep log misses sleeps and marks awake stretches as sleep,
  which gave "averages while awake" under 1 W. Awake/asleep per charge now = sleep log checked against the battery log:
  stretches ≥ 10 min with an entry every ≤ 3 min and > 1.5 W inside a sleep count as awake; gaps > 5 min between
  battery entries outside sleeps count as asleep (or switched off with a cold boot). MacBook Pro unchanged (matches the
  Sleep only view); Air now 2.7–7.8 W awake, 0.1–0.3 W asleep. Averages below 1.5 W are still hidden as a safeguard.
