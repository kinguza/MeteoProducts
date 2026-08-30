#!/usr/bin/env python3
"""
upload_to_supabase.py
======================
Scans the plot directory produced by noaa_pipeline.sh / noaa_plot.py,
uploads each PNG to Supabase Storage, and upserts a metadata row into
the `noaa_products` table so the static website can list/display them.

Requires:
    pip install supabase

Environment variables (set these on the machine running the pipeline,
NEVER in the static site's JS):
    SUPABASE_URL          e.g. https://xxxxxxxx.supabase.co
    SUPABASE_SERVICE_KEY  the service_role key (Project Settings -> API)

Usage:
    python3 upload_to_supabase.py --plots-dir /path/to/NOAA/plots/shum \
        --var shum --level 850 --start-year 1948 --end-year 2026
"""

import argparse
import os
import re
import sys

try:
    from supabase import create_client
except ImportError:
    print("[ERROR] Missing dependency. Run: pip install supabase")
    sys.exit(1)

BUCKET = "noaa-plots"
TABLE = "noaa_products"

# var/level are passed in explicitly (the caller already knows them) rather
# than parsed from the filename -- variable names now include dots and
# underscores (e.g. "air.sig995", "pr_wtr.eatm"), which made a filename-only
# regex unreliable, and "sfc" levels aren't numeric like pressure levels are.
# Only the REMAINDER of the filename -- aggregation, plot type, and for
# timeseries/hovmoller the lat/lon -- still needs parsing, since that part
# stays a small known vocabulary regardless of variable name.
#
# Matches the suffix after "{var}_{level}hPa_", e.g.:
#   daily_spatial_....png
#   monthly_timeseries_20.0N_80.0E.png
#   daily_hovmoller_20.0N.png
SUFFIX_RE = re.compile(
    r"^(?P<aggr>[a-zA-Z]+)_"
    r"(?P<plot_type>spatial|timeseries|hovmoller)"
    r"(?:_(?P<lat>-?\d+\.?\d*)N)?(?:_(?P<lon>-?\d+\.?\d*)E)?"
)


def parse_filename(fname: str, var: str, level: str) -> dict:
    known_prefix = f"{var}_{level}hPa_"
    if not fname.startswith(known_prefix):
        return {}
    m = SUFFIX_RE.match(fname[len(known_prefix):])
    if not m:
        return {}
    d = m.groupdict()
    return {
        "aggr": d["aggr"],
        "plot_type": d["plot_type"],
        "lat": float(d["lat"]) if d.get("lat") else None,
        "lon": float(d["lon"]) if d.get("lon") else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plots-dir", required=True, help="Directory of PNGs to upload (e.g. PLOT_DIR)")
    ap.add_argument("--var", required=True, help="Variable name exactly as used by the pipeline (e.g. shum, air.sig995)")
    ap.add_argument("--level", required=True, help="Level exactly as used by the pipeline (e.g. 850, sfc)")
    ap.add_argument("--start-year", type=int, default=None)
    ap.add_argument("--end-year", type=int, default=None)
    ap.add_argument("--prefix", default="", help="Optional subfolder prefix inside the bucket")
    args = ap.parse_args()

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not url or not key:
        print("[ERROR] Set SUPABASE_URL and SUPABASE_SERVICE_KEY environment variables.")
        sys.exit(1)

    supabase = create_client(url, key)

    if not os.path.isdir(args.plots_dir):
        print(f"[ERROR] Plots directory not found: {args.plots_dir}")
        sys.exit(1)

    pngs = [f for f in os.listdir(args.plots_dir) if f.lower().endswith(".png")]
    if not pngs:
        print(f"[WARN] No PNG files found in {args.plots_dir}")
        return

    uploaded, skipped, failed = 0, 0, 0

    for fname in sorted(pngs):
        local_path = os.path.join(args.plots_dir, fname)
        meta = parse_filename(fname, args.var, args.level)
        if not meta:
            print(f"[WARN] Filename doesn't match expected pattern for var={args.var} level={args.level}, skipping: {fname}")
            skipped += 1
            continue

        storage_path = f"{args.prefix}{fname}" if args.prefix else fname

        # Upload (upsert) file to Storage
        try:
            with open(local_path, "rb") as f:
                supabase.storage.from_(BUCKET).upload(
                    storage_path,
                    f,
                    file_options={"content-type": "image/png", "upsert": "true"},
                )
        except Exception as e:
            print(f"[ERROR] Upload failed for {fname}: {e}")
            failed += 1
            continue

        public_url = supabase.storage.from_(BUCKET).get_public_url(storage_path)

        row = {
            "var": args.var,
            "level_label": args.level,  # always set: "850", "sfc", etc.
            "level_hpa": int(args.level) if args.level.isdigit() else None,
            "aggr": meta["aggr"],
            "plot_type": meta["plot_type"],
            "lat": meta["lat"],
            "lon": meta["lon"],
            "start_year": args.start_year,
            "end_year": args.end_year,
            "file_path": storage_path,
            "public_url": public_url,
            "file_size": os.path.getsize(local_path),
        }

        try:
            supabase.table(TABLE).upsert(row, on_conflict="file_path").execute()
            print(f"[OK] Uploaded + recorded: {fname}")
            uploaded += 1
        except Exception as e:
            print(f"[ERROR] DB upsert failed for {fname}: {e}")
            failed += 1

    print(f"\n[SUMMARY] uploaded={uploaded} skipped={skipped} failed={failed}")


if __name__ == "__main__":
    main()
