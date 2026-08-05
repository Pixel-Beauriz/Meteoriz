#!/usr/bin/env python3
"""
Lädt die MeteoSchweiz Lokalprognosedaten (Open Data, ~5600 Orte, mehrere
30-MB-Sammeldateien) und zerlegt sie in eine winzige JSON-Datei pro Ort
(data/forecasts/<point_id>-<point_type_id>.json), damit die App nur die
paar KB für ihren einen Standort laden muss statt hunderte MB.

Läuft mit reiner Python-Standardbibliothek (kein pip install nötig), damit
es in GitHub Actions ohne Zusatzschritte funktioniert.
"""
import csv
import io
import json
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

STAC_BASE = "https://data.geo.admin.ch/api/stac/v1"
COLLECTION = "ch.meteoschweiz.ogd-local-forecasting"
POI_URL = f"https://data.geo.admin.ch/{COLLECTION}/ogd-local-forecasting_meta_point.csv"
LOCAL_TZ = ZoneInfo("Europe/Zurich")
FORECAST_DAYS = 5  # deckt sich mit forecast_days=5 in der App

# Parameter, die die App tatsächlich rendert (5-Tage-Prognose + Stundenkurve)
HOURLY_PARAMS = {"tre200h0": "temp", "rre150h0": "precip"}
PICTO3H_PARAM = "jww003i0"
DAILY_PARAMS = {"tre200pn": "tmin", "tre200px": "tmax"}
DAILY_PICTO_PARAM = "jp2000d0"
REQUIRED_PARAMS = set(HOURLY_PARAMS) | set(DAILY_PARAMS) | {PICTO3H_PARAM, DAILY_PICTO_PARAM}

OUT_DIR = Path(__file__).resolve().parent.parent / "data" / "forecasts"


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Meteoriz/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def fetch_csv_rows(url: str):
    raw = fetch(url).decode("latin-1")
    return csv.DictReader(io.StringIO(raw), delimiter=";")


def load_pois():
    print(f"Lade Orts-Liste: {POI_URL}")
    pois = []
    for r in fetch_csv_rows(POI_URL):
        try:
            pois.append({
                "id": r["point_id"],
                "type_id": r["point_type_id"],
                "lat": float(r["point_coordinates_wgs84_lat"]),
                "lon": float(r["point_coordinates_wgs84_lon"]),
            })
        except (KeyError, ValueError):
            continue
    print(f"  {len(pois)} Orte geladen")
    return pois


def latest_stac_item():
    today = datetime.now(timezone.utc).strftime("%Y%m%d")
    item_url = f"{STAC_BASE}/collections/{COLLECTION}/items/{today}-ch"
    print(f"Lade STAC-Item: {item_url}")
    item = json.loads(fetch(item_url))
    assets = item["assets"]

    # Params pro Lauf sammeln, damit wir NICHT einfach den zeitlich neusten
    # Lauf nehmen, sondern den neusten, dessen Dateien alle schon vollständig
    # veröffentlicht sind. MeteoSchweiz taucht mit dem Lauf-Zeitstempel schon
    # in den Assets auf, bevor wirklich alle Parameter-Dateien hochgeladen
    # sind — das hat den ersten Testlauf mit einem frischen Lauf scheitern
    # lassen (0 Dateien geschrieben, weil z.B. tre200h0 für den Lauf fehlte).
    params_by_run = {}
    for key in assets:
        parts = key.split(".")
        if len(parts) > 3:
            params_by_run.setdefault(parts[2], set()).add(parts[3])

    complete_runs = sorted(
        run for run, params in params_by_run.items() if REQUIRED_PARAMS <= params
    )
    if not complete_runs:
        raise RuntimeError("Kein Lauf mit allen benötigten Parametern vollständig verfügbar")
    latest_run = complete_runs[-1]
    print(f"  neuster VOLLSTÄNDIGER Lauf: {latest_run} "
          f"({len(params_by_run)} Läufe heute total, {len(assets)} Dateien)")
    return assets, latest_run


def asset_url(assets, run, param):
    for key, asset in assets.items():
        parts = key.split(".")
        if len(parts) > 3 and parts[2] == run and parts[3] == param:
            return asset["href"]
    return None


def parse_time(raw: str) -> datetime:
    return datetime.strptime(raw, "%Y%m%d%H%M").replace(tzinfo=timezone.utc)


def load_param_series(assets, run, param):
    """(point_id, point_type_id) -> {utc_datetime: value} für schnellen Lookup."""
    url = asset_url(assets, run, param)
    if not url:
        print(f"  ⚠ kein Asset für {param} im Lauf {run}")
        return {}
    print(f"Lade Parameter {param}: {url}")
    by_point = {}
    for row in fetch_csv_rows(url):
        key = (row["point_id"], row["point_type_id"])
        try:
            t = parse_time(row["Date"])
            v = float(row[param])
        except (KeyError, ValueError):
            continue
        by_point.setdefault(key, {})[t] = v
    print(f"  {len(by_point)} Orte in dieser Datei")
    return by_point


def local_midnight_today() -> datetime:
    return datetime.now(LOCAL_TZ).replace(hour=0, minute=0, second=0, microsecond=0)


def round_or_none(v, digits):
    return round(v, digits) if v is not None else None


def main():
    pois = load_pois()
    assets, run = latest_stac_item()

    hourly_data = {name: load_param_series(assets, run, p) for p, name in HOURLY_PARAMS.items()}
    picto3h_data = load_param_series(assets, run, PICTO3H_PARAM)
    daily_data = {name: load_param_series(assets, run, p) for p, name in DAILY_PARAMS.items()}
    daily_picto_data = load_param_series(assets, run, DAILY_PICTO_PARAM)

    start_local = local_midnight_today()
    hours = FORECAST_DAYS * 24

    # Ziel-Zeitpunkte EINMAL vorberechnen (nicht pro Ort neu) — als UTC-Datetimes,
    # damit sie direkt als Dict-Key gegen die {utc_datetime: value}-Serien passen.
    hourly_targets = [(start_local + timedelta(hours=h)).astimezone(timezone.utc) for h in range(hours)]
    picto3h_targets = [(start_local + timedelta(hours=i * 3)).astimezone(timezone.utc) for i in range(hours // 3)]
    daily_dates = [(start_local + timedelta(days=d)).date() for d in range(FORECAST_DAYS)]

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    written = 0
    skipped = 0
    poi_index = []  # nur Orte mit tatsächlich geschriebener Datei -> App findet nie einen toten Punkt

    for poi in pois:
        key = (poi["id"], poi["type_id"])
        temp_series = hourly_data["temp"].get(key)
        if not temp_series:
            skipped += 1
            continue
        precip_series = hourly_data["precip"].get(key, {})
        picto3h_series = picto3h_data.get(key, {})
        tmin_series = daily_data["tmin"].get(key, {})
        tmax_series = daily_data["tmax"].get(key, {})
        dpicto_series = daily_picto_data.get(key, {})

        # Für Tageswerte gibt es keinen exakten Stunden-Match nötig — pro Zieltag
        # den ersten Datenpunkt nehmen, dessen lokales Datum passt (linear über die
        # wenigen Einträge pro Ort, i.d.R. <10 — unproblematisch für Performance).
        def daily_lookup(series):
            by_date = {t.astimezone(LOCAL_TZ).date(): v for t, v in series.items()}
            return [by_date.get(d) for d in daily_dates]

        record = {
            "id": f"{poi['id']}-{poi['type_id']}",
            "run": run,
            "start": start_local.isoformat(),
            "hourly": {
                "temp": [round_or_none(temp_series.get(t), 1) for t in hourly_targets],
                "precip": [round_or_none(precip_series.get(t), 2) for t in hourly_targets],
            },
            "picto3h": [int(v) if (v := picto3h_series.get(t)) is not None else None for t in picto3h_targets],
            "daily": {
                # ISO-Datumsstrings mitliefern statt sie im JS aus "start" + Tagesindex
                # zu rekonstruieren — new Date(...).toISOString() würde bei einem lokalen
                # Zeitstempel mit UTC-Offset (z.B. +02:00) auf den falschen Kalendertag
                # zurückrechnen.
                "dates": [d.isoformat() for d in daily_dates],
                "tmin": [round_or_none(v, 1) for v in daily_lookup(tmin_series)],
                "tmax": [round_or_none(v, 1) for v in daily_lookup(tmax_series)],
                "picto": [int(v) if v is not None else None for v in daily_lookup(dpicto_series)],
            },
        }

        out_path = OUT_DIR / f"{poi['id']}-{poi['type_id']}.json"
        out_path.write_text(json.dumps(record, separators=(",", ":")), encoding="utf-8")
        written += 1
        poi_index.append([poi["id"], poi["type_id"], poi["lat"], poi["lon"]])

    # Kompakter Orts-Index für die App: Array-von-Arrays statt Objekten mit
    # Schlüsselnamen spart bei ~5600 Einträgen deutlich Platz.
    index_path = OUT_DIR.parent / "poi.json"
    index_path.write_text(json.dumps(poi_index, separators=(",", ":")), encoding="utf-8")

    print(f"\n✓ {written} Dateien geschrieben nach {OUT_DIR}")
    print(f"  {skipped} Orte übersprungen (keine Temperaturdaten)")
    print(f"✓ Orts-Index geschrieben nach {index_path} ({index_path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    sys.exit(main())
