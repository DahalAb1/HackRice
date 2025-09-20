import os
import json
import http.client
from datetime import datetime
try:
    from zoneinfo import ZoneInfo  # Python 3.9+
except Exception:
    ZoneInfo = None

# --------- CONFIG ---------
LAT = 29.7601
LNG = -95.3701
# Prefer env var; fall back to the literal if you really want.
API_KEY = os.getenv("AMBEE_API_KEY", "050ae24828246bae37de263db68084cff7263073f0e01b965ad6be1a44e6beb4")
TIMEZONE = "America/Chicago"  # your local tz for readability
# --------------------------

conn = http.client.HTTPSConnection("api.ambeedata.com")
headers = {
    "x-api-key": API_KEY,
    "Content-type": "application/json"
}
path = f"/forecast/by-lat-lng?lat=29.7601&lng=-95.3701"
conn.request("GET", path, headers=headers)
res = conn.getresponse()
raw = res.read().decode("utf-8")

# ---- 1) Pretty JSON ----
try:
    parsed = json.loads(raw)
    print(json.dumps(parsed, indent=2))
except json.JSONDecodeError:
    print(raw)
    raise SystemExit("\nResponse was not JSON.")

# ---- 2) Neat Table ----
def to_local(iso_ts: str) -> str:
    """Convert ISO time to local readable time if possible, else return as-is."""
    try:
        # Handle trailing Z
        ts = iso_ts.replace("Z", "+00:00")
        dt = datetime.fromisoformat(ts)
        if ZoneInfo:
            dt = dt.astimezone(ZoneInfo(TIMEZONE))
        return dt.strftime("%Y-%m-%d %H:%M:%S %Z")
    except Exception:
        return iso_ts  # fallback

data = parsed.get("data") or parsed.get("fires") or parsed  # be flexible with field name

# If the API returns a dict with 'data' list of fire points:
if isinstance(data, list):
    # Choose columns you care about; add/remove as needed
    columns = [
        ("lat", "lat"),
        ("lng", "lng"),
        ("confidence", "confidence"),
        ("frp", "frp"),              # Fire Radiative Power
        ("fwi", "fwi"),              # Fire Weather Index
        ("detectedAt", "detectedAt"),
        ("fireType", "fireType"),
        ("fireCategory", "fireCategory"),
        ("source", "source"),
    ]

    # Build rows
    rows = []
    for item in data:
        row = []
        for key, _label in columns:
            val = item.get(key, "")
            if key == "detectedAt" and isinstance(val, str):
                val = to_local(val)
            # Normalize floats for clean look
            if isinstance(val, float):
                val = f"{val:.2f}"
            row.append("" if val is None else str(val))
        rows.append(row)

    # Compute widths
    headers = [label for _, label in columns]
    widths = [len(h) for h in headers]
    for r in rows:
        for i, cell in enumerate(r):
            widths[i] = max(widths[i], len(cell))

    # Print table
    def fmt_row(vals):
        return "  ".join(v.ljust(widths[i]) for i, v in enumerate(vals))

    print("\n=== Neat Table ===")
    print(fmt_row(headers))
    print(fmt_row(["-" * w for w in widths]))
    for r in rows:
        print(fmt_row(r))

else:
    print("\n(No list of fires found under 'data'. Showing keys at top level instead.)")
    print(", ".join(parsed.keys()))

# Optional: write CSV for teammates
def write_csv(path="fires.csv"):
    import csv
    if not isinstance(data, list) or not data:
        return
    cols = ["lat","lng","confidence","frp","fwi","detectedAt","fireType","fireCategory","source"]
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for item in data:
            row = [
                item.get("lat",""),
                item.get("lng",""),
                item.get("confidence",""),
                item.get("frp",""),
                item.get("fwi",""),
                to_local(item.get("detectedAt","")) if isinstance(item.get("detectedAt",""), str) else item.get("detectedAt",""),
                item.get("fireType",""),
                item.get("fireCategory",""),
                item.get("source",""),
            ]
            w.writerow(row)
    print("\nCSV saved to fires.csv")

# Uncomment if you want the CSV file:
# write_csv()
