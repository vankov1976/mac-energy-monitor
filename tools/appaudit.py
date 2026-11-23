#!/usr/bin/env python3
"""App audit, part 2: compares what the views REALLY show (dumps from tools/appaudit.sh) with each other.
Prints "FAIL: ..." for every inconsistency, then "APP AUDIT PASSED" or the number of problems."""
import os, re, sys

out = sys.argv[1]
fails = []
def fail(period, what): fails.append(f"[{period}] {what}")

def load(path):
    """[(role, text, tip)] in reading order; rows as lists of those."""
    items = []
    if not os.path.exists(path): return items
    for line in open(path, encoding="utf-8"):
        m = re.match(r"\s*(\w+): ?(.*?)(?:  ⟨tip: (.*)⟩)?\s*$", line.rstrip("\n"))
        if m: items.append((m.group(1), m.group(2), m.group(3)))
    return items

def rows(items):
    rs, cur = [], None
    for r, t, tip in items:
        if r == "Row":
            cur = []; rs.append(cur); continue
        if cur is not None: cur.append((r, t, tip))
    return rs

def num(s):
    """'87,04' / '0.99' / '1,330' (thousands) / '1.234,5' → float."""
    s = s.strip().replace(" ", "").replace("\xa0", "").replace("≥", "").replace("≈", "").replace("<", "").strip()
    m = re.search(r"[0-9][0-9.,]*", s)
    if not m: return None
    s = m.group(0).rstrip(".,")
    if "," in s and "." in s:
        dec = "," if s.rfind(",") > s.rfind(".") else "."
        s = s.replace("." if dec == "," else ",", "").replace(dec, ".")
    elif "," in s or "." in s:
        sep = "," if "," in s else "."
        parts = s.split(sep)
        s = s.replace(sep, "") if all(len(p) == 3 for p in parts[1:]) and len(parts) > 1 and len(parts[-1]) == 3 else s.replace(sep, ".")
    try: return float(s)
    except ValueError: return None

def minutes(s):
    """'3 d 16 h 8 min' / '8 h' / '< 1 min' / '47 min' → minutes (and the precision of the text in minutes)."""
    if s is None: return None, 0
    d = re.search(r"(\d+) d", s); h = re.search(r"(\d+) h", s); m = re.search(r"(\d+) min", s)
    if not (d or h or m): return None, 0
    v = (int(d.group(1)) * 1440 if d else 0) + (int(h.group(1)) * 60 if h else 0) + (int(m.group(1)) if m else 0)
    return v, (1 if m else 60 if h else 1440)

def close(a, b, tol): return a is not None and b is not None and abs(a - b) <= tol

def texts(items): return [t for r, t, tip in items if r in ("StaticText", "Button", "Link") and t]

def hints(items):
    """The hint texts (their words are separate texts): joined between the cards and the filters."""
    words, on = [], False
    for r, t, tip in items:
        if r == "StaticText" and re.match(r"(Battery|Charger) .* W|.* per hour asleep", t or ""): on = True; continue
        if on and ((t or "").startswith("Sleep details reach back") or r in ("PopUpButton", "RadioButton")): break
        if on and r in ("StaticText", "Link", "Button") and t: words.append(t)
    return re.sub(r" ([.,:;)])", r"\1", " ".join(words))       # words arrive one by one: no space before punctuation

for p in ["24_hours", "7_days", "All"]:
    H = load(f"{out}/{p}.history.txt"); S = load(f"{out}/{p}.sleeps.txt")
    W = load(f"{out}/{p}.wakes.txt"); N = load(f"{out}/{p}.nosleep.txt")
    for name, v in (("History", H), ("Sleep only", S), ("Wake-ups by reason", W), ("Didn't sleep", N)):
        if len(v) < 5: fail(p, f"{name} view not read")
    if not S: continue
    st = texts(S)
    # --- cards of Sleep only
    def after(label, lst):
        return lst[lst.index(label) + 3] if label in lst and lst.index(label) + 3 < len(lst) else None
    try:
        i = st.index("Energy while asleep")
        card_wh, card_avg, card_wakes = num(st[i + 3]), num(st[i + 4]), num(st[i + 5])
    except (ValueError, IndexError):
        fail(p, "Sleep only cards not found"); continue
    asleep_note = next((t for t in st if t.startswith("Asleep ")), None)
    split_note = next((t for t in st if re.match(r"(Battery|Charger) [0-9]", t)), "")
    full = not any(t.startswith("Sleep details reach back") for t in st)
    # --- Sleeps table
    sl = []
    for row in rows(S):
        vals = [(t, tip) for r, t, tip in row if r in ("StaticText", "Button") and t]
        tips = [tip for r, t, tip in row if r == "HelpTag"]
        if len(vals) < 8: continue
        power, cause, wakes, energy, avg, dur, fr, to = [v[0] for v in vals[:8]]
        sl.append(dict(power=power, wakes=int(num(wakes) or 0), energy=energy, wh=num(energy) if "Wh" in energy else None,
                       avg=avg, dur=minutes(dur)[0], frm=fr, to=to, tips=tips, row=f"{fr} – {to}"))
    tabs = [t for r, t, tip in S if r == "RadioButton" and re.match(r"(Sleeps|Wake-ups by reason|Didn't sleep) \(", t)]
    tabn = {re.sub(r" \(.*", "", t): int(num(re.search(r"\((.*)\)", t).group(1))) for t in tabs}
    if tabn.get("Sleeps") != len(sl): fail(p, f"tab says {tabn.get('Sleeps')} sleeps, the table has {len(sl)} rows")
    known = [s for s in sl if s["wh"] is not None]
    sum_wh = sum(s["wh"] for s in known)
    if not close(card_wh, sum_wh, 0.01 + 0.005 * len(known)):
        fail(p, f"card Energy while asleep {card_wh} Wh ≠ sum of the sleeps {sum_wh:.2f} Wh")
    known_min = sum(s["dur"] or 0 for s in known)
    if known_min > 0 and card_avg is not None and not close(card_avg, sum_wh / (known_min / 60), 0.01 + 0.03 * card_avg):
        fail(p, f"card Avg. power {card_avg} W ≠ energy / time of the sleeps with known energy {sum_wh / (known_min / 60):.2f} W")
    all_min = sum(s["dur"] or 0 for s in sl)
    a_val, a_prec = minutes(asleep_note)
    if a_val is not None and abs(a_val - all_min) > a_prec + len(sl):
        fail(p, f"card '{asleep_note}' ≠ sum of the sleeps' durations ({all_min} min)")
    for kind in ("Battery", "Charger"):
        m = re.search(kind + r" ([0-9][0-9.,]*) W", split_note)
        ks = [s for s in known if s["power"] == kind]
        km = sum(s["dur"] or 0 for s in ks)
        if m and km > 0:
            v, calc = num(m.group(1)), sum(s["wh"] for s in ks) / (km / 60)
            if not close(v, calc, 0.01 + 0.03 * v): fail(p, f"card note {kind} {v} W ≠ its sleeps {calc:.2f} W")
    sum_wakes = sum(s["wakes"] for s in sl)
    if card_wakes != sum_wakes: fail(p, f"card Wake-ups {card_wakes} ≠ sum of the sleeps' wake-ups {sum_wakes}")
    if tabn.get("Wake-ups by reason") != card_wakes: fail(p, f"tab Wake-ups by reason ({tabn.get('Wake-ups by reason')}) ≠ card {card_wakes}")
    # tooltips of each sleep against its row
    for s in sl:
        et = next((t for t in s["tips"] if " Wh for the whole sleep" in t or t.startswith("Energy of this sleep unknown")), None)
        if et is None: fail(p, f"{s['row']}: no energy tooltip"); continue
        if s["wh"] is not None:
            if not close(num(et.split(" Wh")[0]), s["wh"], 0.006): fail(p, f"{s['row']}: energy {s['energy']} but tooltip '{et[:40]}'")
            m = re.search(r"including its (\d+) wake-up", et)
            if (int(m.group(1)) if m else 0) != s["wakes"]: fail(p, f"{s['row']}: {s['wakes']} wake-ups but tooltip '{et}'")
        pt = next((t for t in s["tips"] if " asleep" in t and (" % used" in t or "Charge before" in t or "Charged while" in t)), None)
        if s["power"] == "Battery":
            if pt is None: fail(p, f"{s['row']}: Battery without its tooltip"); continue
            m = re.search(r"⏎ ([^⏎]*?) asleep", pt)
            if m and minutes(m.group(1))[0] != s["dur"]: fail(p, f"{s['row']}: duration {s['dur']} min, tooltip '{m.group(1)} asleep'")
            m = re.search(r"([0-9<][0-9.,\s]*) Wh used with ([0-9.,]+) W", pt)
            if m and s["wh"] is not None and not close(num(m.group(1)), s["wh"], 0.006): fail(p, f"{s['row']}: {s['energy']} but tooltip '{m.group(0)}'")
            if m and s["avg"].endswith(" W") and not close(num(m.group(2)), num(s["avg"]), 0.006): fail(p, f"{s['row']}: {s['avg']} but tooltip '{m.group(0)}'")
            m = re.search(r"([0-9]+) % → ([0-9]+) %", pt)
            if m and int(m.group(2)) > int(m.group(1)) + 1: fail(p, f"{s['row']}: Battery but charged {m.group(0)}")
        if s["avg"].endswith(" W") and s["wh"] is not None and s["dur"] and not s["energy"].startswith("<"):
            if not close(num(s["avg"]), s["wh"] / (s["dur"] / 60), 0.01 + 0.06 * num(s["avg"]) + s["wh"] / max(s["dur"], 1) * 60 / max(s["dur"], 1)):
                fail(p, f"{s['row']}: avg {s['avg']} ≠ {s['energy']} / {s['dur']} min")
    # --- History against Sleep only (only where the sleep log covers the whole period)
    ht = texts(H)
    hs = next((t for t in ht if re.match(r"Awake .* asleep ", t)), None)
    try:
        j = ht.index("Sleep"); h_sleep = next(num(t) for t in ht[j:j + 6] if t.endswith(" Wh"))
    except (ValueError, StopIteration):
        h_sleep = None
    if full and (h_sleep is None or hs is None): fail(p, "History's Sleep row or awake/asleep note not read: not compared")
    if full:
        if h_sleep is not None and not close(h_sleep, card_wh, 0.06 + 0.01 * card_wh):
            fail(p, f"History Sleep row {h_sleep} Wh ≠ Sleep only {card_wh} Wh")
        m = re.search(r"asleep (.*?)(?: · |$)", hs or "")
        hv, hp = minutes(m.group(1) if m else None)
        if hv is not None and a_val is not None and abs(hv - a_val) > max(hp, a_prec) + 2:
            fail(p, f"History '{hs}' ≠ Sleep only '{asleep_note}'")
    # --- Wake-ups by reason
    groups = []
    for row in rows(W):
        vals = [t for r, t, tip in row if r == "StaticText" and t]
        if len(vals) >= 3 and num(vals[1]) is not None:
            details = [(num(t)) for t in vals[3:] if re.match(r"\s*\(\d[\d.,]*×\)", t)]
            groups.append(dict(name=vals[0], count=int(num(vals[1])), awake=vals[2], details=details))
    if sum(g["count"] for g in groups) != card_wakes: fail(p, f"wake-up groups add up to {sum(g['count'] for g in groups)}, card {card_wakes}")
    for g in groups:
        reasons = [d for d in g["details"]]
        # the reasons (first block of details) add up to the group's count; planned requests are a subset
        if reasons and sum(reasons) < g["count"]: fail(p, f"{g['name']}: details {sum(reasons)} < {g['count']} wake-ups")
    hx = hints(S)
    for g in groups:
        key = "Wi-Fi or Bluetooth" if g["name"].startswith("Wi-Fi") else "timer set by macOS" if g["name"].startswith("Timer") else None
        if not key: continue
        m = re.search(r"([0-9][0-9.,]*) wake-ups(?: were on a timer set by macOS)?, awake ([^.]*?) in total", hx) if key == "Wi-Fi or Bluetooth" \
            else re.search(r"([0-9][0-9.,]*) wake-ups were on a timer set by macOS, awake ([^.]*?) in total", hx)
        if key == "Wi-Fi or Bluetooth":
            m = re.search(r"come from Wi-Fi or Bluetooth\. ([0-9][0-9.,]*) wake-ups, awake (.*?) in total", hx)
        if m:
            if int(num(m.group(1))) != g["count"]: fail(p, f"hint '{m.group(0)}' ≠ table {g['count']}")
            if minutes(m.group(2))[0] != minutes(g["awake"])[0]: fail(p, f"hint awake '{m.group(2)}' ≠ table {g['awake']}")
    # --- Didn't sleep
    ns = []
    for row in rows(N):
        vals = [t for r, t, tip in row if r == "StaticText" and t]
        if len(vals) >= 6: ns.append(dict(power=vals[0], wh=num(vals[2]) if "Wh" in vals[2] else None, dur=minutes(vals[3])[0], row=f"{vals[4]} – {vals[5]}"))
    if tabn.get("Didn't sleep", 0) != len(ns): fail(p, "tab Didn't sleep (%s) ≠ %d rows" % (tabn.get("Didn't sleep"), len(ns)))
    m = re.search(r"The Mac stayed awake (once|(\d+) times) when it should have slept.*?: (.*?) awake, ([0-9.,]+) Wh", hx)
    nn = tabn.get("Didn't sleep", 0)
    if nn and not m: fail(p, f"{nn} Didn't sleep entries but no hint about them")
    if m:
        times = 1 if m.group(1) == "once" else int(m.group(2))
        if times != nn: fail(p, f"hint says {times} times, tab {nn}")
        if N:
            if minutes(m.group(3))[0] is not None and abs(minutes(m.group(3))[0] - sum(x["dur"] or 0 for x in ns)) > len(ns):
                fail(p, f"hint '{m.group(3)} awake' ≠ sum {sum(x['dur'] or 0 for x in ns)} min")
            if not close(num(m.group(4)), sum(x["wh"] or 0 for x in ns), 0.01 + 0.005 * len(ns)):
                fail(p, f"hint {m.group(4)} Wh ≠ sum {sum(x['wh'] or 0 for x in ns):.2f} Wh")
    marker = next((t for t in st if re.match(r"\d+× awake when it should have slept", t)), None)
    if nn and (marker is None or int(num(marker)) != nn): fail(p, f"marker '{marker}' ≠ {nn} Didn't sleep entries")
    print(f"[{p}] read: {len(sl)} sleeps, {len(groups)} wake-up groups, {len(ns)} didn't sleep, hints {len(hx)} chars, History sleep {h_sleep} Wh"
          + ("" if full else " (sleep log doesn't cover the whole period: History vs Sleep only sleep totals not compared)"))

for f in fails: print("FAIL: " + f)
print(f"{len(fails)} APP AUDIT PROBLEM(S)" if fails else "APP AUDIT PASSED")
