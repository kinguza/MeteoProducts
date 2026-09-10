#!/usr/bin/env python3
"""
all_python_agroproducts.py
==========================
Unified Python tooling for the Agromet database website.

This single script combines the four formerly separate Python modules used
by the NOAA/CHIRPS reanalysis pipeline:

    1. period_aggregate  (calendar-aligned dekad / pentad aggregation)
    2. upload_to_supabase (plot PNG -> Supabase Storage + metadata upsert)
    3. noaa_plot         (one-shot static-plot generation)
    4. plot_api          (FastAPI live-plot service for the website)

All four remain addressable independently through subcommands, so callers
(bash pipeline, manual one-offs, uvicorn) can keep doing what they did
before with no behaviour change. The original modules' logic and CLI
arguments are preserved, with the only differences being:

  * `python3 all_python_agroproducts.py period-aggregate ...`  replaces
    `python3 period_aggregate.py ...`
  * `python3 all_python_agroproducts.py upload ...`  replaces
    `python3 upload_to_supabase.py ...`
  * `python3 all_python_agroproducts.py plot ...`  replaces
    `python3 noaa_plot.py ...` (the script the old bash pipeline used to
    auto-generate into $OUTDIR for static-plot generation)
  * `python3 all_python_agroproducts.py api`  replaces running
    `uvicorn plot_api:app ...` -- exposes the same `app` object
    (so a wrapper like `uvicorn all_python_agroproducts:app ...` still
    works) and provides a __main__-friendly runner that starts uvicorn.

The plotting engine (load_data / plot_spatial / plot_timeseries /
plot_hovmoller / VAR_META) is defined in this single file and reused by
both the `plot` and `api` subcommands, so the live API and the static
plots always render identically with one implementation.

Usage examples
--------------
    # Period aggregation (used by the bash pipelines for dekad/pentad)
    python3 all_python_agroproducts.py period-aggregate \
        --nc input.nc --var precip --period dekad --stat sum --out output.nc

    # One-shot static plot generation (formerly noaa_plot.py)
    python3 all_python_agroproducts.py plot \
        --nc input.nc --var shum --level 850 --aggr monthly \
        --lat 20.0 --lon 80.0 --outdir ./plots

    # Upload pre-rendered plots to Supabase
    python3 all_python_agroproducts.py upload \
        --plots-dir /path/to/NOAA/plots/shum \
        --var shum --level 850 --start-year 1948 --end-year 2026

    # Run the live plot API (port 8000 by default)
    python3 all_python_agroproducts.py api --host 0.0.0.0 --port 8000

    # Or, equivalently with uvicorn:
    uvicorn all_python_agroproducts:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import os
import re
import sys
import types
import warnings

# Silence noisy runtime warnings from matplotlib/numpy/xarray during plotting.
# Same policy as the original noaa_plot.py.
warnings.filterwarnings("ignore")

# =============================================================================
# Shared constants
# =============================================================================
# These names were duplicated across the three original modules; collected
# here so all subcommands read/write the same storage bucket and table.
BUCKET = "noaa-plots"
TABLE = "noaa_products"


# =============================================================================
# 1. Period aggregation (formerly period_aggregate.py)
# =============================================================================
# Calendar-aligned dekad (10-day) and pentad (5-day) aggregation.
#
# CDO has no native operator for these, because they are anchored to
# calendar months (dekad: days 1-10, 11-20, 21-end; pentad: days 1-5,
# 6-10, 11-15, 16-20, 21-25, 26-end), not fixed N-day windows. CDO's
# timselmean/timselsum,N instead chunk the flat sequence of timesteps by
# N regardless of month boundaries -- fine for the first 30-day month,
# then drifts out of calendar alignment. This module groups by pandas
# calendar fields instead, which stays correctly anchored indefinitely.
#
# Used by the bash pipeline for NOAA variables (--stat mean, for state
# variables like temperature/humidity/wind) and for CHIRPS rainfall
# (--stat sum, for accumulative rainfall -- summing daily mm gives
# period-total mm, which is the standard meteorological convention).
def dekad_index(day: int) -> int:
    """1, 2, or 3 -- days 1-10, 11-20, 21-end of month."""
    if day <= 10:
        return 1
    if day <= 20:
        return 2
    return 3


def pentad_index(day: int) -> int:
    """1..6 -- days 1-5, 6-10, 11-15, 16-20, 21-25, 26-end of month
    (the 6th group absorbs the trailing 3-6 days depending on month
    length, rather than creating a short 7th group)."""
    return min((day - 1) // 5 + 1, 6)


def run_period_aggregate(args: argparse.Namespace) -> int:
    # Imports deferred so `--help` works on systems without xarray installed.
    import numpy as np
    import pandas as pd
    import xarray as xr

    ds = xr.open_dataset(args.nc)
    if args.var not in ds:
        print(f"[ERROR] Variable '{args.var}' not found in {args.nc}. "
              f"Available: {list(ds.data_vars)}", file=sys.stderr)
        return 1

    da = ds[args.var]

    # Normalize the time axis to pandas datetime fields regardless of
    # whether xarray decoded it as datetime64 or a cftime calendar.
    time_vals = da["time"].values
    if np.issubdtype(time_vals.dtype, np.datetime64):
        pt = pd.DatetimeIndex(time_vals)
        years, months, days = pt.year.values, pt.month.values, pt.day.values
    else:
        cft = xr.CFTimeIndex(time_vals)
        years = np.array([t.year for t in cft])
        months = np.array([t.month for t in cft])
        days = np.array([t.day for t in cft])

    idx_fn = dekad_index if args.period == "dekad" else pentad_index
    period_idx = np.array([idx_fn(int(d)) for d in days])

    # Single integer key identifying one dekad/pentad instance, e.g.
    # 2020, June, dekad 2 -> 202006 02 -> 20200602
    group_key = years.astype(np.int64) * 10000 + months.astype(np.int64) * 100 + period_idx
    da = da.assign_coords(_group=("time", group_key))

    if args.stat == "sum":
        out = da.groupby("_group").sum(dim="time", skipna=True)
    else:
        out = da.groupby("_group").mean(dim="time", skipna=True)

    # Rebuild a real, usable timestamp per group (first day of that
    # dekad/pentad) from the group labels xarray actually produced --
    # not recomputed separately, to guarantee matching order/values.
    resolved_keys = out["_group"].values
    rep_times = []
    for g in resolved_keys:
        g = int(g)
        yy, rem = divmod(g, 10000)
        mm, pidx = divmod(rem, 100)
        first_day = {1: 1, 2: 11, 3: 21}[pidx] if args.period == "dekad" else (pidx - 1) * 5 + 1
        rep_times.append(np.datetime64(f"{yy:04d}-{mm:02d}-{first_day:02d}"))

    out = out.assign_coords(_group=np.array(rep_times)).rename({"_group": "time"})
    out = out.sortby("time")
    out.attrs = da.attrs

    out.to_dataset(name=args.var).to_netcdf(args.out)
    print(f"[OK] {args.period} {args.stat} -> {args.out} ({out.sizes['time']} periods)")
    return 0


# =============================================================================
# 2. Supabase upload (formerly upload_to_supabase.py)
# =============================================================================
# Scans the plot directory produced by the bash pipeline, uploads each PNG
# to Supabase Storage, and upserts a metadata row into the `noaa_products`
# table so the static website can list/display them.
#
# Environment variables (set these on the machine running the pipeline,
# NEVER in the static site's JS):
#   SUPABASE_URL          e.g. https://xxxxxxxx.supabase.co
#   SUPABASE_SERVICE_KEY  the service_role key (Project Settings -> API)
#
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
_SUFFIX_RE = re.compile(
    r"^(?P<aggr>[a-zA-Z]+)_"
    r"(?P<plot_type>spatial|timeseries|hovmoller)"
    r"(?:_(?P<lat>-?\d+\.?\d*)N)?(?:_(?P<lon>-?\d+\.?\d*)E)?"
)


def _parse_filename(fname: str, var: str, level: str) -> dict:
    known_prefix = f"{var}_{level}hPa_"
    if not fname.startswith(known_prefix):
        return {}
    m = _SUFFIX_RE.match(fname[len(known_prefix):])
    if not m:
        return {}
    d = m.groupdict()
    return {
        "aggr": d["aggr"],
        "plot_type": d["plot_type"],
        "lat": float(d["lat"]) if d.get("lat") else None,
        "lon": float(d["lon"]) if d.get("lon") else None,
    }


def run_upload(args: argparse.Namespace) -> int:
    try:
        from supabase import create_client
    except ImportError:
        print("[ERROR] Missing dependency. Run: pip install supabase")
        return 1

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not url or not key:
        print("[ERROR] Set SUPABASE_URL and SUPABASE_SERVICE_KEY environment variables.")
        return 1

    supabase = create_client(url, key)

    if not os.path.isdir(args.plots_dir):
        print(f"[ERROR] Plots directory not found: {args.plots_dir}")
        return 1

    pngs = [f for f in os.listdir(args.plots_dir) if f.lower().endswith(".png")]
    if not pngs:
        print(f"[WARN] No PNG files found in {args.plots_dir}")
        return 0

    uploaded, skipped, failed = 0, 0, 0

    for fname in sorted(pngs):
        local_path = os.path.join(args.plots_dir, fname)
        meta = _parse_filename(fname, args.var, args.level)
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
    return 0 if failed == 0 else 1


# =============================================================================
# 3. Live plot API (formerly plot_api.py)
# =============================================================================
# Plotting engine (formerly noaa_plot.py).
#
# The live API and the bash pipeline's static-plot step need the same
# rendering code, so we keep it in this single file. Originally this
# code lived in a separate `noaa_plot.py` auto-generated by the bash
# pipeline; now it's defined here once and reused by both the `plot`
# subcommand (one-shot static PNGs) and the `api` subcommand (the
# FastAPI service).
# =============================================================================
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")  # Non-interactive backend; switch to TkAgg/Qt5Agg if --show
import matplotlib.pyplot as plt
from matplotlib.colors import TwoSlopeNorm
import xarray as xr

# ── Variable Metadata ──────────────────────────────────────────────────────
# Long names, units, default colormaps (and anomaly colormaps) for every
# variable the pipeline knows about. Unknown variables fall back to
# generic placeholders at call time.
VAR_META = {
    "shum":         {"long_name": "Specific Humidity",          "units": "kg/kg",   "cmap": "YlGnBu",   "cmap_anom": "BrBG"},
    "uwnd":         {"long_name": "U-Wind (Zonal)",             "units": "m/s",     "cmap": "RdBu_r",   "cmap_anom": "RdBu_r"},
    "vwnd":         {"long_name": "V-Wind (Meridional)",        "units": "m/s",     "cmap": "RdBu_r",   "cmap_anom": "RdBu_r"},
    "air":          {"long_name": "Air Temperature",            "units": "K",       "cmap": "RdYlBu_r", "cmap_anom": "RdBu_r"},
    "omega":        {"long_name": "Vertical Velocity",          "units": "Pa/s",    "cmap": "RdBu",     "cmap_anom": "RdBu"},
    "hgt":          {"long_name": "Geopotential Height",        "units": "m",       "cmap": "viridis",  "cmap_anom": "RdBu_r"},
    "rhum":         {"long_name": "Relative Humidity",          "units": "%",       "cmap": "YlGnBu",   "cmap_anom": "BrBG"},
    "prate":        {"long_name": "Precipitation Rate",         "units": "kg/m2/s", "cmap": "Blues",    "cmap_anom": "BrBG"},
    "slp":          {"long_name": "Sea Level Pressure",         "units": "Pa",      "cmap": "RdYlBu_r", "cmap_anom": "RdBu_r"},
    "pres.sfc":     {"long_name": "Surface Pressure",           "units": "Pa",      "cmap": "RdYlBu_r", "cmap_anom": "RdBu_r"},
    "pr_wtr.eatm":  {"long_name": "Precipitable Water",         "units": "kg/m2",   "cmap": "YlGnBu",   "cmap_anom": "BrBG"},
    "air.sig995":   {"long_name": "Surface Air Temperature",    "units": "K",       "cmap": "RdYlBu_r", "cmap_anom": "RdBu_r"},
    "uwnd.sig995":  {"long_name": "Surface U-Wind",             "units": "m/s",     "cmap": "RdBu_r",   "cmap_anom": "RdBu_r"},
    "vwnd.sig995":  {"long_name": "Surface V-Wind",             "units": "m/s",     "cmap": "RdBu_r",   "cmap_anom": "RdBu_r"},
    "rhum.sig995":  {"long_name": "Surface Relative Humidity",  "units": "%",       "cmap": "YlGnBu",   "cmap_anom": "BrBG"},
    "omega.sig995": {"long_name": "Surface Vertical Velocity",  "units": "Pa/s",    "cmap": "RdBu",     "cmap_anom": "RdBu"},
    "precip":       {"long_name": "CHIRPS Rainfall",            "units": "mm",      "cmap": "Blues",    "cmap_anom": "BrBG"},
}


def _parse_plot_args() -> argparse.Namespace:
    """CLI arguments for the one-shot `plot` subcommand."""
    p = argparse.ArgumentParser(
        description="NOAA/CHIRPS reanalysis visualizer (one-shot static plots)"
    )
    p.add_argument("--nc",        required=True,           help="Path to NetCDF file")
    p.add_argument("--var",       default="shum",          help="Variable name")
    p.add_argument("--lat",       type=float, default=20.0, help="Latitude for time series")
    p.add_argument("--lon",       type=float, default=80.0, help="Longitude for time series")
    p.add_argument("--lat-min",   type=float, default=None, help="Domain crop: min latitude (spatial maps)")
    p.add_argument("--lat-max",   type=float, default=None, help="Domain crop: max latitude (spatial maps)")
    p.add_argument("--lon-min",   type=float, default=None, help="Domain crop: min longitude, -180..180 (spatial maps)")
    p.add_argument("--lon-max",   type=float, default=None, help="Domain crop: max longitude, -180..180 (spatial maps)")
    p.add_argument("--plot-type", default="both", choices=["spatial", "timeseries", "both"])
    p.add_argument("--aggr",      default="daily",          help="Aggregation label")
    p.add_argument("--outdir",    default="./plots",        help="Output plot directory")
    p.add_argument("--level",     default="850",            help="Pressure level label")
    p.add_argument("--colormap",  default=None,             help="Override colormap")
    p.add_argument("--start",     default=None,             help="Start date YYYY-MM-DD")
    p.add_argument("--end",       default=None,             help="End date YYYY-MM-DD")
    p.add_argument("--show",      action="store_true",      help="Show interactive plot")
    p.add_argument("--format",    default="png", choices=["png", "pdf", "svg"])
    p.add_argument("--dpi",       type=int, default=150)
    return p


def load_data(nc_path: str, var_name: str, lat: float, lon: float,
              start: str | None = None, end: str | None = None,
              domain: dict | None = None) -> dict:
    """Load and subset NetCDF data.

    domain, if given, is {"lat_min","lat_max","lon_min","lon_max"} (degrees,
    lon in -180..180) and crops the grid before the spatial mean is taken --
    both for correctness (a regional mean, not a global one) and speed
    (matplotlib/cartopy render far less data for a small region).
    """
    print(f"[INFO] Loading: {nc_path}")
    ds = xr.open_dataset(nc_path, decode_times=True)

    # Find variable (case-insensitive fallback)
    if var_name not in ds:
        candidates = [v for v in ds.data_vars if var_name.lower() in v.lower()]
        if not candidates:
            raise ValueError(f"Variable '{var_name}' not found. Available: {list(ds.data_vars)}")
        var_name = candidates[0]
        print(f"[INFO] Using variable: {var_name}")

    da = ds[var_name]

    # Squeeze pressure level dimension if present
    if "level" in da.dims and da.sizes["level"] == 1:
        da = da.squeeze("level")
    elif "level" in da.dims:
        # Take the first level if multiple
        print(f"[WARN] Multiple levels found. Taking level index 0.")
        da = da.isel(level=0)

    # Normalize dimension names
    rename_map = {}
    for d in da.dims:
        if d.lower() in ("latitude", "lat"):
            rename_map[d] = "lat"
        elif d.lower() in ("longitude", "lon"):
            rename_map[d] = "lon"
        elif d.lower() in ("time", "t"):
            rename_map[d] = "time"
    if rename_map:
        da = da.rename(rename_map)

    # Normalize longitude: convert 0-360 to -180 to 180 if needed
    if "lon" in da.coords and da.lon.max() > 180:
        da = da.assign_coords(lon=(da.lon + 180) % 360 - 180)
        da = da.sortby("lon")

    # Ensure lat is sorted ascending
    if "lat" in da.coords and da.lat.values[0] > da.lat.values[-1]:
        da = da.sortby("lat")

    # Crop to a bounding box if requested (spatial "any domain" support)
    if domain:
        da = da.sel(
            lat=slice(domain["lat_min"], domain["lat_max"]),
            lon=slice(domain["lon_min"], domain["lon_max"]),
        )
        if da.sizes.get("lat", 0) == 0 or da.sizes.get("lon", 0) == 0:
            raise ValueError(f"Domain crop produced an empty grid: {domain}")

    # Time filter
    if start or end:
        da = da.sel(time=slice(start, end))

    print(f"[INFO] Data shape: {dict(da.sizes)}")
    print(f"[INFO] Time range: {str(da.time.values[0])[:10]} to {str(da.time.values[-1])[:10]}")
    print(f"[INFO] Lat range : {float(da.lat.min()):.2f} to {float(da.lat.max()):.2f}")
    print(f"[INFO] Lon range : {float(da.lon.min()):.2f} to {float(da.lon.max()):.2f}")

    # Extract time series at (lat, lon)
    ts = da.sel(lat=lat, lon=lon, method="nearest")
    actual_lat = float(ts.lat.values)
    actual_lon = float(ts.lon.values)
    print(f"[INFO] Nearest grid point: lat={actual_lat:.2f}, lon={actual_lon:.2f}")

    # Compute climatological mean (spatial) -- mean over time
    spatial_mean = da.mean(dim="time")

    return {
        "da":         da,
        "ts":         ts,
        "spatial":    spatial_mean,
        "var_name":   var_name,
        "actual_lat": actual_lat,
        "actual_lon": actual_lon,
        "domain":     domain,
    }


def plot_spatial(da_spatial, var_name: str, args, meta: dict,
                 actual_lat: float, actual_lon: float, domain: dict | None = None):
    """Plot global/regional spatial map with optional cartopy.

    domain, if given, restricts the map extent to a bounding box instead
    of the whole globe -- {"lat_min","lat_max","lon_min","lon_max"}.
    """
    try:
        import cartopy.crs as ccrs
        import cartopy.feature as cfeature
        HAS_CARTOPY = True
    except ImportError:
        HAS_CARTOPY = False
        print("[WARN] cartopy not available -- plotting without map features")

    cmap = args.colormap or meta.get("cmap", "viridis")
    data = da_spatial.values
    lats = da_spatial.lat.values
    lons = da_spatial.lon.values

    # Detect if anomaly (use diverging colormap)
    is_anomaly = "anomaly" in args.aggr.lower() or "anom" in str(args.nc).lower()
    if is_anomaly:
        cmap = args.colormap or meta.get("cmap_anom", "RdBu_r")
        vmax = np.nanpercentile(np.abs(data), 98)
        norm = TwoSlopeNorm(vcenter=0, vmin=-vmax, vmax=vmax)
    else:
        vmin = np.nanpercentile(data, 2)
        vmax = np.nanpercentile(data, 98)
        norm = None

    fig_title = (f"{meta.get('long_name', var_name)} | {args.level} hPa | "
                 f"{args.aggr.title()} Mean")

    if HAS_CARTOPY:
        proj = ccrs.PlateCarree()
        fig, ax = plt.subplots(
            figsize=(14, 7),
            subplot_kw={"projection": proj},
            facecolor="#0f0f1a"
        )
        ax.set_facecolor("#0f0f1a")

        if is_anomaly:
            cf = ax.contourf(lons, lats, data, levels=21, cmap=cmap,
                             norm=norm, transform=proj)
        else:
            cf = ax.contourf(lons, lats, data, levels=21, cmap=cmap,
                             vmin=vmin, vmax=vmax, transform=proj)

        # Contour lines
        cs = ax.contour(lons, lats, data, levels=10, colors="white",
                        linewidths=0.4, alpha=0.4, transform=proj)

        # Map features
        ax.add_feature(cfeature.COASTLINE, linewidth=0.8, edgecolor="#aaaacc")
        ax.add_feature(cfeature.BORDERS,   linewidth=0.4, edgecolor="#888899", linestyle="--")
        ax.add_feature(cfeature.LAND,      facecolor="none", edgecolor="none")
        ax.add_feature(cfeature.OCEAN,     facecolor="#0a0a15", alpha=0.3)
        ax.gridlines(draw_labels=True, linewidth=0.4, color="gray",
                     alpha=0.5, linestyle="--",
                     xlocs=range(-180, 181, 30), ylocs=range(-90, 91, 30))

        # Mark selected coordinate (only meaningful if it's inside the shown extent)
        ax.plot(actual_lon, actual_lat, marker="*", color="#ff6b6b",
                markersize=14, transform=proj, zorder=10,
                label=f"Selected: {actual_lat:.1f}N, {actual_lon:.1f}E")
        ax.legend(loc="lower left", fontsize=9,
                  facecolor="#1a1a2e", edgecolor="#444466", labelcolor="white")

        if domain:
            ax.set_extent(
                [domain["lon_min"], domain["lon_max"], domain["lat_min"], domain["lat_max"]],
                crs=proj,
            )
        else:
            ax.set_global()

    else:
        # Fallback: plain matplotlib
        fig, ax = plt.subplots(figsize=(14, 7), facecolor="#0f0f1a")
        ax.set_facecolor("#0f0f1a")
        lons2d, lats2d = np.meshgrid(lons, lats)
        if is_anomaly:
            cf = ax.pcolormesh(lons2d, lats2d, data, cmap=cmap, norm=norm, shading="auto")
        else:
            cf = ax.pcolormesh(lons2d, lats2d, data, cmap=cmap,
                               vmin=vmin, vmax=vmax, shading="auto")
        ax.plot(actual_lon, actual_lat, "r*", markersize=14,
                label=f"Selected: {actual_lat:.1f}N, {actual_lon:.1f}E")
        ax.set_xlabel("Longitude", color="white")
        ax.set_ylabel("Latitude",  color="white")
        ax.tick_params(colors="white")
        ax.spines[:].set_color("#444466")
        ax.legend(fontsize=9, facecolor="#1a1a2e", edgecolor="#444466", labelcolor="white")

    # Colorbar
    cbar = plt.colorbar(cf, ax=ax, orientation="horizontal",
                        pad=0.04, fraction=0.03, aspect=50)
    cbar.set_label(f"{meta.get('long_name', var_name)} ({meta.get('units', '')})",
                   color="white", fontsize=11)
    cbar.ax.tick_params(colors="white", labelsize=8)
    cbar.outline.set_edgecolor("#444466")

    ax.set_title(fig_title, color="white", fontsize=14, fontweight="bold", pad=12)
    fig.patch.set_facecolor("#0f0f1a")

    os.makedirs(args.outdir, exist_ok=True)
    if domain:
        fname = (f"{var_name}_{args.level}hPa_{args.aggr}_spatial_"
                  f"{domain['lat_min']:.1f}_{domain['lat_max']:.1f}_"
                  f"{domain['lon_min']:.1f}_{domain['lon_max']:.1f}.{args.format}")
    else:
        fname = f"{var_name}_{args.level}hPa_{args.aggr}_spatial.{args.format}"
    fpath = os.path.join(args.outdir, fname)
    plt.savefig(fpath, dpi=args.dpi, bbox_inches="tight",
                facecolor="#0f0f1a", edgecolor="none")
    print(f"[OK] Saved spatial map -> {fpath}")

    if args.show:
        matplotlib.use("TkAgg")
        plt.show()
    plt.close(fig)
    return fpath


def plot_timeseries(ts, var_name: str, args, meta: dict,
                    actual_lat: float, actual_lon: float):
    """Plot time series with rolling mean and trend line."""
    from scipy import stats as scipy_stats

    times  = pd.to_datetime(ts.time.values)
    values = ts.values.astype(float)

    # Remove NaN
    mask   = ~np.isnan(values)
    times  = times[mask]
    values = values[mask]

    if len(values) == 0:
        print("[ERROR] No valid data at selected point.")
        return None

    # Compute rolling mean (window depends on aggregation)
    win_map = {"daily": 30, "monthly": 12, "seasonal": 4, "annual": 5,
               "pentad": 10, "climatology": 30, "anomaly": 30}
    win = win_map.get(args.aggr.lower(), 12)
    ts_series   = pd.Series(values, index=times)
    rolling_mean = ts_series.rolling(window=win, center=True, min_periods=1).mean()

    # Linear trend
    x_num = np.arange(len(values), dtype=float)
    slope, intercept, r_val, p_val, std_err = scipy_stats.linregress(x_num, values)
    trend = slope * x_num + intercept

    # Unit conversion for display
    display_values = values.copy()
    display_label  = meta.get("units", "")
    if var_name == "shum":
        display_values = values * 1000
        display_label  = "g/kg"

    rolling_display = rolling_mean.values.copy()
    trend_display   = trend.copy()
    if var_name == "shum":
        rolling_display *= 1000
        trend_display   *= 1000

    # ── Figure ──────────────────────────────────────────────────────────────
    fig, axes = plt.subplots(2, 1, figsize=(14, 9),
                              gridspec_kw={"height_ratios": [3, 1]},
                              facecolor="#0f0f1a")
    ax_main, ax_bar = axes

    # Color based on positive/negative for anomaly
    is_anomaly = "anomaly" in args.aggr.lower()
    if is_anomaly:
        bar_colors = np.where(display_values >= 0, "#ff6b6b", "#6bb5ff")
        ax_main.axhline(0, color="#888899", linewidth=0.8, linestyle="--", alpha=0.6)
    else:
        bar_colors = "#3a7bd5"

    # Main time series
    ax_main.set_facecolor("#0f0f1a")
    ax_main.fill_between(times, display_values, alpha=0.25,
                          color="#3a7bd5", linewidth=0)
    ax_main.plot(times, display_values, color="#3a7bd5",
                  linewidth=0.7, alpha=0.6, label="Observed")
    ax_main.plot(times, rolling_display, color="#f0c040",
                  linewidth=2.0, label=f"{win}-step Rolling Mean")
    ax_main.plot(times, trend_display, color="#ff6b6b",
                  linewidth=1.5, linestyle="--",
                  label=f"Trend: {slope * (365 if args.aggr=='daily' else 1):.4g}/yr"
                        f"  (p={p_val:.3f})")

    # Mark selected point
    mid_idx = len(times) // 2
    ax_main.axvline(times[0], color="none")  # dummy for spacing

    ax_main.set_title(
        f"{meta.get('long_name', var_name)} | {args.level} hPa | "
        f"({actual_lat:.2f}N, {actual_lon:.2f}E) | {args.aggr.title()}",
        color="white", fontsize=13, fontweight="bold", pad=10
    )
    ax_main.set_ylabel(f"{meta.get('long_name', var_name)} ({display_label})",
                        color="white", fontsize=11)
    ax_main.tick_params(colors="white", labelsize=9)
    ax_main.spines[:].set_color("#2a2a3e")
    ax_main.spines["bottom"].set_color("#444466")
    ax_main.spines["left"].set_color("#444466")
    ax_main.legend(fontsize=9, facecolor="#1a1a2e",
                    edgecolor="#444466", labelcolor="white")
    ax_main.grid(axis="y", color="#2a2a3e", linewidth=0.5, linestyle=":")
    ax_main.set_facecolor("#0d0d1a")

    # Annual bar chart (bottom panel)
    ax_bar.set_facecolor("#0d0d1a")
    annual_ts = ts_series.resample("YE").mean()
    if var_name == "shum":
        annual_ts = annual_ts * 1000
    bar_c = ["#ff6b6b" if v >= annual_ts.mean() else "#6bb5ff"
              for v in annual_ts.values]
    ax_bar.bar(annual_ts.index.year, annual_ts.values,
                color=bar_c, width=0.7, alpha=0.85, edgecolor="none")
    ax_bar.axhline(annual_ts.mean(), color="#f0c040",
                    linewidth=1.2, linestyle="--", alpha=0.7, label="Annual mean")
    ax_bar.set_ylabel("Annual\nMean", color="white", fontsize=8)
    ax_bar.tick_params(colors="white", labelsize=8)
    ax_bar.spines[:].set_color("#2a2a3e")
    ax_bar.spines["bottom"].set_color("#444466")
    ax_bar.spines["left"].set_color("#444466")
    ax_bar.set_facecolor("#0d0d1a")
    ax_bar.grid(axis="y", color="#2a2a3e", linewidth=0.4, linestyle=":")
    ax_bar.legend(fontsize=8, facecolor="#1a1a2e",
                   edgecolor="#444466", labelcolor="white")

    plt.tight_layout(rect=[0, 0, 1, 1], h_pad=0.5)

    os.makedirs(args.outdir, exist_ok=True)
    fname = (f"{var_name}_{args.level}hPa_{args.aggr}_"
             f"timeseries_{actual_lat:.1f}N_{actual_lon:.1f}E.{args.format}")
    fpath = os.path.join(args.outdir, fname)
    plt.savefig(fpath, dpi=args.dpi, bbox_inches="tight",
                facecolor="#0f0f1a", edgecolor="none")
    print(f"[OK] Saved time series -> {fpath}")

    if args.show:
        matplotlib.use("TkAgg")
        plt.show()
    plt.close(fig)
    return fpath


def plot_hovmoller(da, var_name: str, args, meta: dict,
                   actual_lat: float, actual_lon: float):
    """Plot a Hovmoller diagram (longitude-time) at selected latitude."""
    cmap = args.colormap or meta.get("cmap", "RdBu_r")

    # Slice lat band +/- 2.5 degrees
    lat_band = da.sel(lat=slice(actual_lat - 2.5, actual_lat + 2.5)).mean(dim="lat")
    data = lat_band.values.astype(float)
    if var_name == "shum":
        data *= 1000
    times = pd.to_datetime(lat_band.time.values)
    lons  = lat_band.lon.values

    fig, ax = plt.subplots(figsize=(14, 8), facecolor="#0f0f1a")
    ax.set_facecolor("#0d0d1a")

    vmin = np.nanpercentile(data, 2)
    vmax = np.nanpercentile(data, 98)
    cf   = ax.contourf(lons, np.arange(len(times)), data,
                        levels=21, cmap=cmap, vmin=vmin, vmax=vmax)
    ax.contour(lons, np.arange(len(times)), data,
               levels=10, colors="white", linewidths=0.3, alpha=0.3)

    # Y-axis: time labels
    n_ticks = min(12, len(times))
    tick_idx = np.linspace(0, len(times) - 1, n_ticks, dtype=int)
    ax.set_yticks(tick_idx)
    ax.set_yticklabels([str(times[i])[:10] for i in tick_idx],
                        color="white", fontsize=8)
    ax.set_xlabel("Longitude", color="white", fontsize=11)
    ax.set_ylabel("Time",      color="white", fontsize=11)
    ax.tick_params(colors="white", labelsize=9)
    ax.spines[:].set_color("#444466")

    cbar = plt.colorbar(cf, ax=ax, orientation="vertical", pad=0.02, fraction=0.025)
    cbar.set_label(f"{meta.get('long_name', var_name)} ({meta.get('units', '')})",
                   color="white", fontsize=10)
    cbar.ax.tick_params(colors="white", labelsize=8)
    cbar.outline.set_edgecolor("#444466")

    ax.set_title(f"Hovmoller (Lon-Time) | {meta.get('long_name', var_name)} | "
                 f"Lat band ~{actual_lat:.1f} | {args.level} hPa",
                 color="white", fontsize=13, fontweight="bold", pad=10)

    os.makedirs(args.outdir, exist_ok=True)
    fname = (f"{var_name}_{args.level}hPa_{args.aggr}_"
             f"hovmoller_{actual_lat:.1f}N.{args.format}")
    fpath = os.path.join(args.outdir, fname)
    plt.savefig(fpath, dpi=args.dpi, bbox_inches="tight",
                facecolor="#0f0f1a", edgecolor="none")
    print(f"[OK] Saved Hovmoller -> {fpath}")
    plt.close(fig)
    return fpath


def run_plot(args: argparse.Namespace) -> int:
    """One-shot static-plot subcommand. Produces the same PNGs the original
    noaa_plot.py main() function did: spatial map + time series (+ Hovmoller)
    for the given variable/aggregation/point.
    """
    if not os.path.isfile(args.nc):
        print(f"[ERROR] File not found: {args.nc}")
        return 1

    meta = VAR_META.get(args.var, {
        "long_name": args.var.upper(),
        "units": "",
        "cmap": "viridis",
        "cmap_anom": "RdBu_r",
    })

    # Optional bounding box for spatial maps
    domain = None
    if None not in (args.lat_min, args.lat_max, args.lon_min, args.lon_max):
        domain = {
            "lat_min": args.lat_min, "lat_max": args.lat_max,
            "lon_min": args.lon_min, "lon_max": args.lon_max,
        }

    # Load data
    result = load_data(args.nc, args.var,
                       args.lat, args.lon,
                       args.start, args.end,
                       domain=domain)

    plots_saved = []

    # Spatial map
    if args.plot_type in ("spatial", "both"):
        p = plot_spatial(result["spatial"], result["var_name"],
                         args, meta,
                         result["actual_lat"], result["actual_lon"],
                         domain=result["domain"])
        plots_saved.append(p)

    # Time series
    if args.plot_type in ("timeseries", "both"):
        p = plot_timeseries(result["ts"], result["var_name"],
                            args, meta,
                            result["actual_lat"], result["actual_lon"])
        if p:
            plots_saved.append(p)

    # Hovmoller (always generated when timeseries or both)
    if args.plot_type in ("timeseries", "both"):
        try:
            p = plot_hovmoller(result["da"], result["var_name"],
                               args, meta,
                               result["actual_lat"], result["actual_lon"])
            plots_saved.append(p)
        except Exception as e:
            print(f"[WARN] Hovmoller skipped: {e}")

    print(f"\n[OK] Done! {len(plots_saved)} plot(s) saved to: {args.outdir}")
    for p in plots_saved:
        print(f"     -> {p}")
    return 0


# =============================================================================
# Live plot-generation API for the NOAA reanalysis website.
#
# Instead of only serving pre-rendered PNGs from Supabase, this service lets
# the frontend send ANY (lat, lon) for a time series, or ANY bounding box for
# a spatial map, and returns a freshly rendered PNG -- generated from the
# full aggregated NetCDF files the pipeline already produces.
#
# It does not duplicate the plotting logic: it imports load_data / plot_spatial
# / plot_timeseries / plot_hovmoller / VAR_META directly from the noaa_plot.py
# that the bash pipeline writes into $OUTDIR, so the live API and the batch
# pipeline always render identically.
#
# Requires:
#   pip install fastapi uvicorn[standard]
#   (plus everything noaa_plot.py needs: xarray, matplotlib, cartopy, ...)
#
# Run:
#   export NOAA_OUTDIR=/path/to/NOAA        # same OUTDIR the pipeline used
#   python3 all_python_agroproducts.py api --host 0.0.0.0 --port 8000
#   # ...or equivalently:
#   uvicorn all_python_agroproducts:app --host 0.0.0.0 --port 8000

# Configuration is set at module import time (so uvicorn can pick up `app`
# directly without going through __main__).
OUTDIR = os.environ.get("NOAA_OUTDIR", os.path.join(os.getcwd(), "NOAA"))
AGG_ROOT = os.path.join(OUTDIR, "aggregated")
NOAA_PLOT_PY = os.path.join(OUTDIR, "noaa_plot.py")
CACHE_DIR = os.path.join(OUTDIR, "live_cache")
STATE_DIR = os.path.join(OUTDIR, ".state")
UPDATE_LOG = os.path.join(OUTDIR, "logs", "update.log")
UPDATE_LOCK = os.path.join(STATE_DIR, "update.lock")
UPDATE_STATUS = os.path.join(STATE_DIR, "update_status.json")
# Comma-separated list of allowed frontend origins, e.g.
#   ALLOWED_ORIGINS="https://your-site.com,https://www.your-site.com"
ALLOWED_ORIGINS = os.environ.get("ALLOWED_ORIGINS", "*").split(",")

# Admin token: a shared secret required to trigger the update endpoint.
# Set ADMIN_TOKEN in the server's environment; if unset, admin endpoints
# are disabled (return 503) so a misconfigured deployment doesn't expose
# arbitrary command execution.
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "").strip()

# Path to the bash pipeline script. The admin endpoint shells out to it
# for the actual update work (incremental update, Supabase re-upload).
# Resolved relative to this Python file so it works regardless of cwd.
_PIPELINE_SH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "all_agro_dataproces.sh",
)


# FastAPI imports are deferred so the rest of the file (and the
# period-aggregate / upload subcommands) remain importable on machines
# that don't have FastAPI installed. The API objects below are only
# created when the user actually runs the `api` subcommand or imports
# `app` for uvicorn.
def _build_app():
    """Construct the FastAPI app. Imported lazily so missing fastapi/
    uvicorn doesn't break the other subcommands.
    """
    from fastapi import FastAPI, HTTPException, Query
    from fastapi.middleware.cors import CORSMiddleware
    from fastapi.responses import FileResponse
    from pydantic import BaseModel, Field

    os.makedirs(CACHE_DIR, exist_ok=True)

    if not os.path.isdir(AGG_ROOT):
        raise RuntimeError(
            f"{AGG_ROOT} not found. Run the bash pipeline at least once "
            f"(any subcommand + any --var) so aggregated NetCDFs exist, or "
            f"set NOAA_OUTDIR to the correct directory."
        )

    # Plotting functions (load_data / plot_spatial / plot_timeseries /
    # plot_hovmoller / VAR_META) are defined at module level in this same
    # file -- no need to import from a separate noaa_plot.py anymore. The
    # merged design means the live API and the static-plot step share one
    # rendering implementation, by construction.
    noaa_plot = sys.modules[__name__]

    app = FastAPI(title="Agromet Live Plot API")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=ALLOWED_ORIGINS,
        allow_methods=["GET", "POST"],
        allow_headers=["*"],
    )

    # ── Locating aggregated NetCDF files produced by the pipeline ─────────
    def find_aggregated_file(var: str, level: str, aggr: str) -> str:
        """
        Aggregated files are named:
            {AGG_ROOT}/{var}/{var}_{level}hPa_{aggr}_{start_year}_{end_year}.nc
        start/end vary run to run (especially with --start all --end all), so
        glob for it and pick the one covering the widest year range.
        """
        pattern = os.path.join(AGG_ROOT, var, f"{var}_{level}hPa_{aggr}_*_*.nc")
        matches = glob.glob(pattern)
        if not matches:
            raise HTTPException(
                status_code=404,
                detail=(f"No aggregated file for var={var}, level={level}, aggr={aggr}. "
                        f"Run the pipeline for this combination first (see run_all_variables.sh)."),
            )

        def year_span(path: str) -> int:
            m = re.search(r"_(\d{4})_(\d{4})\.nc$", path)
            if not m:
                return 0
            return int(m.group(2)) - int(m.group(1))

        return max(matches, key=year_span)

    def list_available_combos() -> list:
        """Scan AGG_ROOT for every var/level/aggr combination currently on disk."""
        combos = []
        if not os.path.isdir(AGG_ROOT):
            return combos
        for var in sorted(os.listdir(AGG_ROOT)):
            var_dir = os.path.join(AGG_ROOT, var)
            if not os.path.isdir(var_dir):
                continue
            for fname in sorted(os.listdir(var_dir)):
                m = re.match(rf"^{re.escape(var)}_([a-zA-Z0-9]+)hPa_([a-zA-Z]+)_(\d{{4}})_(\d{{4}})\.nc$", fname)
                if m:
                    level, aggr, start, end = m.groups()
                    combos.append({
                        "var": var, "level": level, "aggr": aggr,
                        "start_year": int(start), "end_year": int(end),
                    })
        return combos

    # ── Request schemas ────────────────────────────────────────────────────
    class TimeseriesRequest(BaseModel):
        var: str
        level: str = "850"
        aggr: str = "daily"
        lat: float
        lon: float
        start: str | None = Field(default=None, description="YYYY-MM-DD")
        end: str | None = Field(default=None, description="YYYY-MM-DD")
        include_hovmoller: bool = False

    class SpatialRequest(BaseModel):
        var: str
        level: str = "850"
        aggr: str = "monthly"
        lat_min: float
        lat_max: float
        lon_min: float
        lon_max: float
        start: str | None = Field(default=None, description="YYYY-MM-DD")
        end: str | None = Field(default=None, description="YYYY-MM-DD")

    # ── Caching -- identical requests reuse the same rendered PNG on disk ─
    def cache_path(prefix: str, payload: BaseModel) -> str:
        key = hashlib.sha256(payload.model_dump_json().encode()).hexdigest()[:24]
        return os.path.join(CACHE_DIR, f"{prefix}_{key}.png")

    def make_args(**overrides) -> types.SimpleNamespace:
        """Build the argparse.Namespace-shaped object noaa_plot.py's functions expect."""
        defaults = dict(
            nc=None, var="shum", lat=-5.0, lon=36.0,
            lat_min=None, lat_max=None, lon_min=None, lon_max=None,
            plot_type="both", aggr="daily", outdir=CACHE_DIR, level="850",
            colormap=None, start=None, end=None, show=False,
            format="png", dpi=140,
        )
        defaults.update(overrides)
        return types.SimpleNamespace(**defaults)

    # ── Endpoints ──────────────────────────────────────────────────────────
    @app.get("/api/health")
    def health():
        return {"status": "ok", "outdir": OUTDIR}

    @app.get("/api/meta")
    def meta():
        """
        What the frontend needs to constrain the UI: which var/level/aggr
        combinations actually have data ready, so the map/coordinate picker
        doesn't let someone request something that doesn't exist yet.
        """
        return {"combos": list_available_combos()}

    @app.post("/api/timeseries")
    def timeseries(req: TimeseriesRequest):
        cpath = cache_path("ts", req)
        if os.path.isfile(cpath):
            return FileResponse(cpath, media_type="image/png")

        nc_path = find_aggregated_file(req.var, req.level, req.aggr)
        meta_info = noaa_plot.VAR_META.get(req.var, {
            "long_name": req.var.upper(), "units": "", "cmap": "viridis", "cmap_anom": "RdBu_r"
        })

        try:
            result = noaa_plot.load_data(
                nc_path, req.var, req.lat, req.lon, req.start, req.end, domain=None
            )
            args = make_args(
                nc=nc_path, var=req.var, level=req.level, aggr=req.aggr,
                lat=req.lat, lon=req.lon, start=req.start, end=req.end,
                plot_type="timeseries",
            )
            fpath = noaa_plot.plot_timeseries(
                result["ts"], result["var_name"], args, meta_info,
                result["actual_lat"], result["actual_lon"],
            )
            if fpath is None:
                raise HTTPException(status_code=422, detail="No valid data at that point/date range.")
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Plot generation failed: {e}")

        os.replace(fpath, cpath)  # normalize to the cache key filename
        return FileResponse(cpath, media_type="image/png")

    @app.post("/api/spatial")
    def spatial(req: SpatialRequest):
        if req.lat_min >= req.lat_max or req.lon_min >= req.lon_max:
            raise HTTPException(status_code=422, detail="lat_min/lon_min must be less than lat_max/lon_max.")

        cpath = cache_path("sp", req)
        if os.path.isfile(cpath):
            return FileResponse(cpath, media_type="image/png")

        nc_path = find_aggregated_file(req.var, req.level, req.aggr)
        meta_info = noaa_plot.VAR_META.get(req.var, {
            "long_name": req.var.upper(), "units": "", "cmap": "viridis", "cmap_anom": "RdBu_r"
        })
        domain = {
            "lat_min": req.lat_min, "lat_max": req.lat_max,
            "lon_min": req.lon_min, "lon_max": req.lon_max,
        }
        center_lat = (req.lat_min + req.lat_max) / 2
        center_lon = (req.lon_min + req.lon_max) / 2

        try:
            result = noaa_plot.load_data(
                nc_path, req.var, center_lat, center_lon, req.start, req.end, domain=domain
            )
            args = make_args(
                nc=nc_path, var=req.var, level=req.level, aggr=req.aggr,
                lat=center_lat, lon=center_lon, start=req.start, end=req.end,
                plot_type="spatial",
            )
            fpath = noaa_plot.plot_spatial(
                result["spatial"], result["var_name"], args, meta_info,
                result["actual_lat"], result["actual_lon"], domain=result["domain"],
            )
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Plot generation failed: {e}")

        os.replace(fpath, cpath)
        return FileResponse(cpath, media_type="image/png")

    # =====================================================================
    # Admin endpoints -- trigger the incremental update from the website
    # =====================================================================
    # These let the admin click "Refresh data" on the website instead of
    # needing shell access. Designed to be safe under concurrent use:
    #   - ADMIN_TOKEN (env var) gates access; the browser sends it in
    #     the X-Admin-Token header. If unset, the endpoints return 503
    #     so a misconfigured deployment can't run arbitrary commands.
    #   - Only one update runs at a time, guarded by both a flock-style
    #     lock file and an asyncio.Lock.
    #   - Output is captured to a log file the SSE stream tails, so the
    #     admin page shows real progress.
    import asyncio as _asyncio
    import json as _json
    import shlex as _shlex
    import subprocess as _subprocess
    import time as _time
    from datetime import datetime, timezone

    os.makedirs(STATE_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(UPDATE_LOG), exist_ok=True)

    _update_task: _asyncio.Task | None = None
    _update_lock = _asyncio.Lock()

    def _check_admin_token(provided: str | None) -> None:
        """Reject the request if the admin token doesn't match."""
        if not ADMIN_TOKEN:
            raise HTTPException(
                status_code=503,
                detail="Admin endpoints disabled: set ADMIN_TOKEN on the server to enable.",
            )
        if not provided or provided != ADMIN_TOKEN:
            raise HTTPException(status_code=401, detail="Invalid or missing admin token.")

    def _read_status() -> dict:
        """Read the current update status JSON, or a default if missing."""
        if os.path.isfile(UPDATE_STATUS):
            try:
                with open(UPDATE_STATUS, "r", encoding="utf-8") as f:
                    return _json.load(f)
            except (OSError, ValueError):
                pass
        return {
            "running": False,
            "started_at": None,
            "finished_at": None,
            "exit_code": None,
            "sources": [],
            "message": "No update has been run yet.",
        }

    def _write_status(**kwargs) -> None:
        """Persist the current update status atomically."""
        status = _read_status()
        status.update(kwargs)
        tmp = UPDATE_STATUS + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            _json.dump(status, f, indent=2)
        os.replace(tmp, UPDATE_STATUS)

    def _last_update_iso_from_state() -> str | None:
        """Pull the .last_update timestamp written by the bash script."""
        state_file = os.path.join(STATE_DIR, "last_update")
        if os.path.isfile(state_file):
            try:
                return open(state_file).read().strip()
            except OSError:
                return None
        return None

    @app.get("/api/admin/status")
    def admin_status(x_admin_token: str | None = Query(default=None, alias="X-Admin-Token", include_in_schema=False)):
        # FastAPI doesn't have first-class header-param support without
        # importing Header, but Query with an alias works for both query
        # and header-based access. The frontend will use the header.
        _check_admin_token(x_admin_token)
        status = _read_status()
        status["last_update"] = _last_update_iso_from_state()
        status["log_path"] = UPDATE_LOG
        status["admin_token_set"] = bool(ADMIN_TOKEN)
        return status

    @app.post("/api/admin/update")
    def admin_update(x_admin_token: str | None = Query(default=None, alias="X-Admin-Token", include_in_schema=False)):
        _check_admin_token(x_admin_token)

        if not os.path.isfile(_PIPELINE_SH):
            raise HTTPException(
                status_code=500,
                detail=f"Pipeline script not found at {_PIPELINE_SH}.",
            )

        nonlocal _update_task  # type: ignore[misc]
        if _update_task and not _update_task.done():
            raise HTTPException(
                status_code=409,
                detail="An update is already running. Wait for it to finish or call /api/admin/update/cancel.",
            )

        # Record the start BEFORE launching, so concurrent clients see
        # the running state immediately and a status poll right after
        # the POST returns accurate info.
        now_iso = datetime.now(timezone.utc).isoformat()
        _write_status(
            running=True,
            started_at=now_iso,
            finished_at=None,
            exit_code=None,
            sources=["noaa", "chirps"],
            message="Update started.",
            pid=None,
        )

        # Clear the log so the SSE stream only shows the current run.
        # (Backups of the previous log are kept as update.log.1 etc.)
        if os.path.isfile(UPDATE_LOG):
            for i in range(5, 0, -1):
                older = f"{UPDATE_LOG}.{i}"
                if os.path.isfile(older):
                    os.replace(older, f"{UPDATE_LOG}.{i + 1}")
            os.replace(UPDATE_LOG, f"{UPDATE_LOG}.1")

        async def _run() -> None:
            async with _update_lock:
                # Pass the env explicitly so the bash script sees
                # NOAA_OUTDIR / SUPABASE_* set in the Python process.
                env = os.environ.copy()
                env["NOAA_OUTDIR"] = OUTDIR
                env.setdefault("PYTHONUNBUFFERED", "1")

                cmd = ["bash", _PIPELINE_SH, "update", "--outdir", OUTDIR]
                log_fh = open(UPDATE_LOG, "a", encoding="utf-8", buffering=1)
                try:
                    log_fh.write(f"\n=== Update started at {now_iso} ===\n")
                    log_fh.flush()
                    proc = _subprocess.Popen(
                        cmd,
                        stdout=log_fh,
                        stderr=_subprocess.STDOUT,
                        env=env,
                        cwd=os.path.dirname(_PIPELINE_SH),
                    )
                    _write_status(pid=proc.pid)
                    exit_code = proc.wait()
                    log_fh.write(f"\n=== Update finished with exit code {exit_code} ===\n")
                except Exception as e:  # noqa: BLE001
                    log_fh.write(f"\n=== Update failed with exception: {e} ===\n")
                    exit_code = 1
                finally:
                    log_fh.close()

                _write_status(
                    running=False,
                    finished_at=datetime.now(timezone.utc).isoformat(),
                    exit_code=exit_code,
                    message="Update finished successfully." if exit_code == 0
                            else f"Update failed (exit code {exit_code}). See log for details.",
                )

        _update_task = _asyncio.create_task(_run())
        return {"status": "started", "started_at": now_iso, "log_path": UPDATE_LOG}

    @app.post("/api/admin/update/cancel")
    def admin_update_cancel(x_admin_token: str | None = Query(default=None, alias="X-Admin-Token", include_in_schema=False)):
        _check_admin_token(x_admin_token)
        # Best-effort cancel: the bash script doesn't currently expose a
        # cancel hook, so we kill its process group if we have one. Most
        # useful when the update is stuck on a long download.
        status = _read_status()
        pid = status.get("pid")
        if not pid:
            raise HTTPException(status_code=400, detail="No running update to cancel.")
        try:
            import signal
            os.killpg(os.getpgid(int(pid)), signal.SIGTERM)
        except (OSError, ValueError) as e:
            raise HTTPException(status_code=500, detail=f"Cancel failed: {e}")
        return {"status": "cancel_signal_sent", "pid": pid}

    @app.get("/api/admin/update/stream")
    def admin_update_stream(x_admin_token: str | None = Query(default=None, alias="X-Admin-Token", include_in_schema=False)):
        """Server-Sent Events stream of the update log. The frontend
        subscribes via EventSource to get live progress.

        Note: FastAPI doesn't auto-handle auth for SSE, so we check the
        token from the query parameter (EventSource can't set headers
        in the browser).
        """
        _check_admin_token(x_admin_token)

        from fastapi.responses import StreamingResponse

        def event_gen():
            # Send any existing log content first so a refresh mid-run
            # shows context.
            if os.path.isfile(UPDATE_LOG):
                with open(UPDATE_LOG, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        yield f"data: {line.rstrip()}\n\n"
            # Then tail the file: send each new line as it appears.
            last_size = os.path.getsize(UPDATE_LOG) if os.path.isfile(UPDATE_LOG) else 0
            status = _read_status()
            while status.get("running"):
                _time.sleep(0.5)
                if not os.path.isfile(UPDATE_LOG):
                    continue
                size = os.path.getsize(UPDATE_LOG)
                if size > last_size:
                    with open(UPDATE_LOG, "r", encoding="utf-8", errors="replace") as f:
                        f.seek(last_size)
                        for line in f:
                            yield f"data: {line.rstrip()}\n\n"
                    last_size = size
                status = _read_status()
            # Send a final 'done' event so the JS side knows to stop.
            yield f"event: done\ndata: {_json.dumps(status)}\n\n"

        return StreamingResponse(event_gen(), media_type="text/event-stream")

    return app


# Try to build the app eagerly so `uvicorn all_python_agroproducts:app`
# keeps working. If fastapi isn't installed (e.g. only using the
# period-aggregate or upload subcommands), fall back to lazy construction
# via `_build_app` -- the `api` subcommand will require it explicitly.
try:
    app = _build_app()
except Exception as _e:  # noqa: BLE001
    app = None
    _APP_BUILD_ERROR = _e


def run_api(args: argparse.Namespace) -> int:
    """Start the FastAPI server via uvicorn. The 'app' module-level
    object is reused so a previously imported uvicorn that pinned
    `all_python_agroproducts:app` continues to work identically.
    """
    try:
        import uvicorn
    except ImportError:
        print("[ERROR] Missing dependency. Run: pip install uvicorn[standard]")
        return 1

    if app is None:
        # Lazy build (in case eager build above was skipped because
        # fastapi wasn't installed yet, or because the first eager
        # build failed and we want to retry now that deps are present).
        try:
            built = _build_app()
        except Exception as e:
            print(f"[ERROR] Could not build API: {e}")
            return 1
        globals()["app"] = built
    uvicorn.run(app, host=args.host, port=args.port)
    return 0


# =============================================================================
# Argument parsing
# =============================================================================
def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Unified Python tooling for the Agromet database website: "
            "period aggregation, Supabase upload, and live plot API. "
            "Use one of the subcommands below."
        )
    )
    sub = parser.add_subparsers(dest="cmd", required=True, metavar="SUBCOMMAND")

    # ── period-aggregate ──────────────────────────────────────────────────
    p_agg = sub.add_parser(
        "period-aggregate",
        help="Calendar-aligned dekad/pentad aggregation (formerly period_aggregate.py)",
    )
    p_agg.add_argument("--nc", required=True)
    p_agg.add_argument("--var", required=True)
    p_agg.add_argument("--period", required=True, choices=["dekad", "pentad"])
    p_agg.add_argument(
        "--stat", required=True, choices=["sum", "mean"],
        help="sum for accumulative quantities (rainfall); mean for state variables",
    )
    p_agg.add_argument("--out", required=True)

    # ── upload ────────────────────────────────────────────────────────────
    p_up = sub.add_parser(
        "upload",
        help="Upload plot PNGs to Supabase Storage + metadata table "
             "(formerly upload_to_supabase.py)",
    )
    p_up.add_argument("--plots-dir", required=True, help="Directory of PNGs to upload (e.g. PLOT_DIR)")
    p_up.add_argument("--var", required=True, help="Variable name exactly as used by the pipeline (e.g. shum, air.sig995)")
    p_up.add_argument("--level", required=True, help="Level exactly as used by the pipeline (e.g. 850, sfc)")
    p_up.add_argument("--start-year", type=int, default=None)
    p_up.add_argument("--end-year", type=int, default=None)
    p_up.add_argument("--prefix", default="", help="Optional subfolder prefix inside the bucket")

    # ── plot ──────────────────────────────────────────────────────────────
    # Replaces the noaa_plot.py script the old bash pipeline auto-generated
    # into $OUTDIR. Same flags, same output filenames (so the Supabase
    # uploader's filename parser still works without changes).
    p_plot = sub.add_parser(
        "plot",
        help="One-shot static plots from an aggregated NetCDF "
             "(formerly noaa_plot.py --nc ...)",
    )
    p_plot.add_argument("--nc",        required=True,           help="Path to NetCDF file")
    p_plot.add_argument("--var",       default="shum",          help="Variable name")
    p_plot.add_argument("--lat",       type=float, default=20.0, help="Latitude for time series")
    p_plot.add_argument("--lon",       type=float, default=80.0, help="Longitude for time series")
    p_plot.add_argument("--lat-min",   type=float, default=None, help="Domain crop: min latitude (spatial maps)")
    p_plot.add_argument("--lat-max",   type=float, default=None, help="Domain crop: max latitude (spatial maps)")
    p_plot.add_argument("--lon-min",   type=float, default=None, help="Domain crop: min longitude, -180..180 (spatial maps)")
    p_plot.add_argument("--lon-max",   type=float, default=None, help="Domain crop: max longitude, -180..180 (spatial maps)")
    p_plot.add_argument("--plot-type", default="both", choices=["spatial", "timeseries", "both"])
    p_plot.add_argument("--aggr",      default="daily",          help="Aggregation label")
    p_plot.add_argument("--outdir",    default="./plots",        help="Output plot directory")
    p_plot.add_argument("--level",     default="850",            help="Pressure level label")
    p_plot.add_argument("--colormap",  default=None,             help="Override colormap")
    p_plot.add_argument("--start",     default=None,             help="Start date YYYY-MM-DD")
    p_plot.add_argument("--end",       default=None,             help="End date YYYY-MM-DD")
    p_plot.add_argument("--show",      action="store_true",      help="Show interactive plot")
    p_plot.add_argument("--format",    default="png", choices=["png", "pdf", "svg"])
    p_plot.add_argument("--dpi",       type=int, default=150)

    # ── api ───────────────────────────────────────────────────────────────
    p_api = sub.add_parser(
        "api",
        help="Run the live plot-generation API (formerly plot_api.py)",
    )
    p_api.add_argument("--host", default="0.0.0.0", help="Bind host (default: 0.0.0.0)")
    p_api.add_argument("--port", type=int, default=8000, help="Bind port (default: 8000)")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.cmd == "period-aggregate":
        return run_period_aggregate(args)
    if args.cmd == "upload":
        return run_upload(args)
    if args.cmd == "plot":
        return run_plot(args)
    if args.cmd == "api":
        return run_api(args)

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
