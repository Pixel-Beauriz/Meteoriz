#!/usr/bin/env python3
"""
Erzeugt die Ortsliste für die Ortssuche der App aus den MeteoSchweiz-Stammdaten
(gleiche Quelle wie build_forecast_data.py) und schreibt sie als
2_finale_app/Meteoriz/Resources/Web/places.js ins App-Bundle.

Die Liste ändert sich selten (Postleitzahl-Zentren, Stationen, Berge/Hütten) und
wird deshalb fest in die App eingebaut statt zur Laufzeit geladen: die Suche
funktioniert so sofort und auch offline. Bei Bedarf einfach neu ausführen:

    python3 scripts/build_places.py

Eintrag pro Ort: [Name, Breite, Länge, Gewicht, Art]
  Gewicht = Anzahl Punkte mit diesem Namen (Zürich hat viele Postleitzahl-Gebiete,
            ein Dorf nur eines) – dient als einfacher Hinweis auf die Ortsgrösse.
  Art     = 0 Ortschaft (hat eine Postleitzahl), 1 reine Messstation (Pass, Gipfel, Flugplatz …),
            2 Berg/Hütte. Die Suche zeigt Ortschaften zuerst.
Läuft mit reiner Python-Standardbibliothek.
"""
import csv
import io
import json
import urllib.request
from collections import defaultdict
from pathlib import Path

COLLECTION = "ch.meteoschweiz.ogd-local-forecasting"
POI_URL = f"https://data.geo.admin.ch/{COLLECTION}/ogd-local-forecasting_meta_point.csv"
OUT = Path(__file__).resolve().parent.parent / "2_finale_app" / "Meteoriz" / "Resources" / "Web" / "places.js"

STATION = "1"
POSTAL_CENTER = "2"
POINT_OF_INTEREST = "3"


def fetch_rows():
    req = urllib.request.Request(POI_URL, headers={"User-Agent": "Meteoriz/1.0"})
    raw = urllib.request.urlopen(req, timeout=60).read().decode("latin-1")
    return list(csv.DictReader(io.StringIO(raw), delimiter=";"))


def main():
    rows = fetch_rows()
    by_name = defaultdict(list)
    for r in rows:
        name = (r.get("point_name") or "").strip()
        # Technische Messpunkte (Viadukte, Flughafen-Messstellen, «Lausanne 26» …) sind keine Orte.
        if not name or any(ch.isdigit() for ch in name) or "_" in name:
            continue
        try:
            lat = float(r["point_coordinates_wgs84_lat"])
            lon = float(r["point_coordinates_wgs84_lon"])
        except (KeyError, ValueError):
            continue
        by_name[name].append((r.get("postal_code") or "", r["point_type_id"], lat, lon))

    places = []
    for name, pts in by_name.items():
        # Bevorzugt den Ortschafts-Punkt (Postleitzahl-Zentrum); gibt es nur eine Messstation,
        # die Station; zuletzt Berge/Hütten. Bei mehreren Gebieten mit gleichem Namen
        # (z.B. Zürich) die kleinste Postleitzahl = Zentrum.
        for kind, wanted in ((0, POSTAL_CENTER), (1, STATION), (2, POINT_OF_INTEREST)):
            pool = [p for p in pts if p[1] == wanted]
            if pool:
                break
        plz, type_id, lat, lon = sorted(pool, key=lambda p: (p[0] == "", p[0]))[0]
        places.append([name, round(lat, 4), round(lon, 4), len(pts), kind])

    places.sort(key=lambda p: p[0].lower())
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        "// Automatisch erzeugt von scripts/build_places.py – nicht von Hand ändern.\n"
        "window.MCH_PLACES=" + json.dumps(places, ensure_ascii=False, separators=(",", ":")) + ";\n",
        encoding="utf-8",
    )
    print(f"✓ {len(places)} Orte geschrieben nach {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
