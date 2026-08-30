#!/bin/bash
# =============================================================================
# all_agro_dataproces.sh
# =============================================================================
# Unified Agromet data-processing pipeline.
#
# This single script supersedes the three formerly separate bash entry points
# used by the Agromet database website:
#
#     1. noaa_pipeline.sh        (one NOAA NCEP reanalysis variable/level)
#     2. run_chirps_pipeline.sh  (CHIRPS v2.0 daily rainfall, 0.25deg)
#     3. run_all_variables.sh    (loop over the full NOAA var/level catalog,
#                                 plus CHIRPS, in a single run)
#
# All three are still addressable through subcommands, so callers can keep
# doing what they did before with no behavioural change:
#
#     bash all_agro_dataproces.sh noaa       --var shum --level 850
#     bash all_agro_dataproces.sh chirps     --start 2000 --end 2020
#     bash all_agro_dataproces.sh all        # full catalog
#     bash all_agro_dataproces.sh all --skip-static-plots --clean-raw
#
# Subcommand summary
# ------------------
#   noaa       Process ONE NOAA NCEP variable/level (was: noaa_pipeline.sh).
#              Use this for ad-hoc processing of a single combination.
#
#   chirps     Process CHIRPS v2.0 daily rainfall (was: run_chirps_pipeline.sh).
#              Output writes to the SAME ${OUTDIR}/aggregated/ tree the NOAA
#              pipeline uses, so plot_api.py picks up rainfall with no
#              additional configuration.
#
#   all        Loop the full catalog (was: run_all_variables.sh): all NOAA
#              pressure variables across the levels they actually exist at,
#              all surface variables, and CHIRPS. Generates the aggregated
#              NetCDFs the live plot API needs.
#
# Each subcommand supports the same options the original script did, plus
# the few cross-cutting ones (--outdir, --clean-raw, etc.) that the merged
# design makes uniform.
#
# Dependencies (same as the originals):
#   - wget or curl
#   - CDO (Climate Data Operators)
#   - NCO (ncrcat, ncks) -- optional but recommended
#   - Python 3 with: xarray, matplotlib, cartopy, numpy, pandas, scipy
#   - For `upload` step: supabase (pip install supabase)
#   - For `api` step:   fastapi + uvicorn[standard]
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Shared defaults
# ─────────────────────────────────────────────────────────────────────────────
# These are overridable per subcommand, but most callers will only need to
# set --outdir (the single root everything writes under).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTDIR="$(pwd)/NOAA"

# NOAA PSL base URLs (NCEP Reanalysis I Daily Pressure Level Data).
BASE_URL_DAILY="https://downloads.psl.noaa.gov/Datasets/ncep.reanalysis/Dailies/pressure"
BASE_URL_SURFACE="https://downloads.psl.noaa.gov/Datasets/ncep.reanalysis/Dailies/surface"

# CHIRPS v2.0 global daily, 0.25deg (chosen over p05 for a manageable
# download/processing size while still supporting the full 1981-present
# record). Variable: precip (mm/day). Dims: time, latitude, longitude.
BASE_URL_CHIRPS="https://data.chc.ucsb.edu/products/CHIRPS-2.0/global_daily/netcdf/p25"

# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}>>> $* ${NC}\n"; }

# Shared Python entry point (one file now contains the three formerly
# separate Python modules). Each helper that previously wrote a Python
# script into $OUTDIR now points the pipeline at this single file.
SHARED_PY="${SCRIPT_DIR}/all_python_agroproducts.py"

# ─────────────────────────────────────────────────────────────────────────────
# Show top-level help
# ─────────────────────────────────────────────────────────────────────────────
show_top_help() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    echo
    echo "Subcommands:"
    echo "  noaa     Process one NOAA NCEP variable/level"
    echo "  chirps   Process CHIRPS v2.0 daily rainfall"
    echo "  all      Loop the full catalog (NOAA pressure + surface + CHIRPS)"
    echo "  update   Incremental update: pull only the new days since the last"
    echo "           successful run, append to existing aggregations. Designed"
    echo "           for daily cron / Task Scheduler (low data cost)."
    echo
    echo "Run 'bash $0 <subcommand> --help' for subcommand-specific options."
    echo "Run 'bash $0 --version' for the script version."
}

show_version() {
    echo "all_agro_dataproces.sh v1.0 (merged: noaa_pipeline.sh + run_chirps_pipeline.sh + run_all_variables.sh)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse top-level args: pick a subcommand, then dispatch to that subcommand's
# own option parser. We keep the per-subcommand option blocks identical to
# the originals so callers don't have to relearn anything.
# ─────────────────────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
    show_top_help
    exit 0
fi

case "$1" in
    --help|-h)   show_top_help; exit 0 ;;
    --version|-V) show_version; exit 0 ;;
    noaa|chirps|all|update) SUBCOMMAND="$1"; shift ;;
    *)
        log_error "Unknown subcommand: $1"
        echo
        show_top_help
        exit 1
        ;;
esac


# =============================================================================
# Shared helpers (used by more than one subcommand)
# =============================================================================

# Variable classification for NOAA downloads.
#
# NOTE on names: pressure vars are one file per year covering all levels
# (level extracted afterward via cdo). Surface vars are NOT simply
# "${var}.${year}.nc" -- most carry a level suffix baked into the filename
# itself (verified against the live NOAA server), so the "variable name"
# here IS the exact download stem. slp is the one exception (no suffix).
# skt and prate are NOT in this dataset's Dailies/surface catalog (they
# live elsewhere, e.g. a Gaussian-grid product) -- omitted until verified,
# rather than guessing a path that would silently 404.
SURFACE_VARS=("slp" "pres.sfc" "pr_wtr.eatm" "air.sig995" "uwnd.sig995" "vwnd.sig995" "rhum.sig995" "omega.sig995")
PRESSURE_VARS=("shum" "uwnd" "vwnd" "air" "omega" "hgt" "rhum")

is_surface_var() {
    local v="$1"
    for sv in "${SURFACE_VARS[@]}"; do
        [[ "$sv" == "$v" ]] && return 0
    done
    return 1
}

check_dep() {
    if command -v "$1" &>/dev/null; then
        log_success "$1 found: $(command -v $1)"
    else
        log_error "$1 not found. Please install it."
        [[ "${2:-}" == "required" ]] && exit 1
    fi
}

detect_latest_available_year() {
    # Determine which URL base applies for THIS variable (surface vs pressure).
    local probe_var="$1"
    local probe_base
    if is_surface_var "$probe_var"; then
        probe_base="$BASE_URL_SURFACE"
    else
        probe_base="$BASE_URL_DAILY"
    fi

    local candidate
    candidate=$(date +%Y)
    # Walk backwards from the current year until a file actually exists
    while [[ "$candidate" -ge "${DATASET_START_YEAR:-1948}" ]]; do
        if wget -q --spider --timeout=15 --tries=2 \
                "${probe_base}/${probe_var}.${candidate}.nc" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
        candidate=$((candidate - 1))
    done
    # Fallback if probing fails entirely (e.g. offline) -- caller should
    # already have a sane default in this case.
    echo ""
}

detect_latest_chirps_year() {
    local candidate
    candidate=$(date +%Y)
    while [[ "$candidate" -ge "${DATASET_START_YEAR:-1981}" ]]; do
        if wget -q --spider --timeout=15 --tries=2 \
                "${BASE_URL_CHIRPS}/chirps-v2.0.${candidate}.days_p25.nc" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
        candidate=$((candidate - 1))
    done
    echo ""
}

# Common dependency checks used by every subcommand.
check_common_deps() {
    log_section "Checking Dependencies"
    check_dep wget    required
    check_dep cdo     required
    check_dep python3 required
    check_dep ncrcat  optional
    check_dep ncks    optional

    python3 -c "import xarray, matplotlib, numpy, pandas" 2>/dev/null \
        && log_success "Core Python packages found" \
        || { log_error "Missing Python packages. Run: pip install xarray matplotlib numpy pandas scipy cartopy"; exit 1; }

    python3 -c "import cartopy" 2>/dev/null \
        && log_success "cartopy found" \
        || log_warn "cartopy not found -- spatial maps will be skipped. Install: pip install cartopy"
}

# Run the period-aggregate Python helper (formerly the standalone
# period_aggregate.py script). All subcommands go through this one entry
# point, so behaviour stays uniform across NOAA and CHIRPS.
run_period_agg() {
    local nc="$1"
    local var="$2"
    local period="$3"
    local stat="$4"
    local out="$5"
    python3 "$SHARED_PY" period-aggregate \
        --nc "$nc" --var "$var" \
        --period "$period" --stat "$stat" \
        --out "$out"
}

# Run a single aggregation case (used by both NOAA and CHIRPS) so the
# dispatch table below stays small. Returns 0 on success, 1 on failure.
# The caller already has AGGR / BASE_NC / PREFIX / VAR / START_YEAR /
# END_YEAR / OUT_NC / AGG_DIR in scope.
run_aggregation() {
    local AGGR="$1" BASE_NC="$2" PREFIX="$3" VAR="$4" \
           START_YEAR="$5" END_YEAR="$6" OUT_NC="$7" AGG_DIR="$8"
    local STEP_OK=true

    case "$AGGR" in
        daily)
            # Daily is the base -- just copy
            cp "$BASE_NC" "$OUT_NC" || STEP_OK=false
            ;;

        monthly)
            # Monthly mean (NOAA state vars) / monthly sum (CHIRPS) -- the
            # caller decides which CDO operator to use by setting the
            # surrounding MONTH_OP / SEAS_OP / YEAR_OP variables.
            cdo -O -f nc4 -z zip_6 "${MONTH_OP:-monmean}" "$BASE_NC" "$OUT_NC" || STEP_OK=false
            ;;

        seasonal)
            # Seasonal mean (DJF, MAM, JJA, SON)
            local SEAS_TMP="${AGG_DIR}/${PREFIX}_seasonal_tmp.nc"
            cdo -O -f nc4 -z zip_6 "${SEAS_OP:-seasmean}" "$BASE_NC" "$SEAS_TMP" || STEP_OK=false
            if $STEP_OK; then
                cdo -O -f nc4 -z zip_6 -select,month=3,6,9,12 "$SEAS_TMP" "$OUT_NC" || STEP_OK=false
            fi
            rm -f "$SEAS_TMP"
            ;;

        annual)
            # Annual mean (NOAA) / annual sum (CHIRPS) -- set via ANNUAL_OP
            cdo -O -f nc4 -z zip_6 "${ANNUAL_OP:-yearmean}" "$BASE_NC" "$OUT_NC" || STEP_OK=false
            ;;

        climatology)
            # Long-term daily climatology (mean of each calendar day)
            cdo -O -f nc4 -z zip_6 ydaymean "$BASE_NC" "$OUT_NC" || STEP_OK=false
            ;;

        anomaly)
            # Daily anomalies (subtract daily climatology)
            local CLIM_NC="${AGG_DIR}/${PREFIX}_climatology_${START_YEAR}_${END_YEAR}.nc"
            if [[ ! -f "$CLIM_NC" ]]; then
                log_info "Computing climatology first for anomaly..."
                cdo -O -f nc4 -z zip_6 ydaymean "$BASE_NC" "$CLIM_NC" || STEP_OK=false
            fi
            if $STEP_OK; then
                cdo -O -f nc4 -z zip_6 ydaysub "$BASE_NC" "$CLIM_NC" "$OUT_NC" || STEP_OK=false
            fi
            ;;

        dekad)
            # Calendar-aligned 10-day. --stat controlled by the caller via
            # DEKAD_OP ("mean" or "sum"). The "stat" comes from a
            # dedicated helper, not CDO, because CDO's timselmean ignores
            # month boundaries and drifts out of calendar alignment.
            run_period_agg "$BASE_NC" "$VAR" "dekad" "${DEKAD_OP:-mean}" "$OUT_NC" || STEP_OK=false
            ;;

        pentad)
            # Calendar-aligned 5-day. --stat controlled via PENTAD_OP.
            run_period_agg "$BASE_NC" "$VAR" "pentad" "${PENTAD_OP:-mean}" "$OUT_NC" || STEP_OK=false
            ;;

        *)
            log_warn "Unknown aggregation: '${AGGR}'. Skipping."
            return 2  # distinguish "skipped" from "failed"
            ;;
    esac

    if $STEP_OK && [[ -s "$OUT_NC" ]]; then
        log_success "${AGGR} -> ${OUT_NC}"
        return 0
    else
        log_error "${AGGR} aggregation failed (command error or empty/missing output)."
        rm -f "$OUT_NC"  # don't leave a corrupt/partial file behind
        return 1
    fi
}

# The merged Python script is self-contained: it defines load_data /
# plot_spatial / plot_timeseries / plot_hovmoller / VAR_META inline and
# exposes them via the `plot` and `api` subcommands. No plotting helper
# file needs to be written into $OUTDIR anymore -- the bash pipeline
# just calls `python3 all_python_agroproducts.py plot ...` directly.
write_plot_script_link() {
    local OUTDIR="$1"
    # Kept as a no-op for backwards-compatible call sites. The merged
    # Python module is self-contained, so there's nothing to symlink.
    :
}

# Run the upload step if both the script and credentials are available.
run_upload_step() {
    local PLOT_DIR="$1" VAR="$2" LEVEL="$3" \
           START_YEAR="$4" END_YEAR="$5"

    if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_KEY:-}" ]]; then
        log_warn "SUPABASE_URL / SUPABASE_SERVICE_KEY not set -- skipping upload."
        log_warn "Export them (e.g. in ~/.bashrc) to enable automatic upload."
        return 0
    fi

    python3 "$SHARED_PY" upload \
        --plots-dir  "$PLOT_DIR" \
        --var        "$VAR" \
        --level      "$LEVEL" \
        --start-year "$START_YEAR" \
        --end-year   "$END_YEAR" \
        --prefix     "${VAR}/"
}

# Run the plot step (formerly Step 6 of noaa_pipeline.sh / Step 5 of
# run_chirps_pipeline.sh) -- invokes the merged Python script's `plot`
# subcommand, which contains the same load_data / plot_spatial /
# plot_timeseries / plot_hovmoller functions the original noaa_plot.py
# inlined into $OUTDIR.
#
# Signature kept identical to the original so the per-subcommand callers
# (run_noaa / run_chirps) don't have to change: PYTHON_SCRIPT is now
# ignored -- the merged script is loaded directly from $SHARED_PY.
run_plot_step() {
    local PYTHON_SCRIPT_UNUSED="$1" AGG_DIR="$2" PLOT_DIR="$3" \
           VAR="$4" LEVEL="$5" PREFIX="$6" \
           USER_LAT="$7" USER_LON="$8" \
           PLOT_TYPE="$9" AGGR="${10}" START_YEAR="${11}" END_YEAR="${12}"

    local NC_FILE="${AGG_DIR}/${PREFIX}_${AGGR}_${START_YEAR}_${END_YEAR}.nc"
    [[ -f "$NC_FILE" ]] || { log_warn "Aggregated file not found for ${AGGR}: ${NC_FILE} -- skipping plot"; return 0; }

    log_info "Plotting ${AGGR} (${VAR} @ ${LEVEL}) | lat=${USER_LAT}, lon=${USER_LON}"
    python3 "$SHARED_PY" plot \
        --nc        "$NC_FILE"   \
        --var       "$VAR"       \
        --lat       "$USER_LAT"  \
        --lon       "$USER_LON"  \
        --plot-type "$PLOT_TYPE" \
        --aggr      "$AGGR"      \
        --level     "$LEVEL"     \
        --outdir    "$PLOT_DIR"  \
        --dpi       150          \
        --format    png
}


# =============================================================================
# Subcommand: noaa
# =============================================================================
# One NOAA NCEP reanalysis variable/level per run.
run_noaa() {
    # Defaults (overridable by CLI)
    local VAR="shum"
    local LEVEL="850"
    local START_YEAR="all"
    local END_YEAR="all"
    local AGGREGATIONS="daily,monthly,seasonal,annual"
    local LAUNCH_PLOT=true
    local USER_LAT=-5.0
    local USER_LON=36.0
    local PLOT_TYPE="both"
    local CLEAN_RAW=false
    local OUTDIR="$DEFAULT_OUTDIR"
    local DATASET_START_YEAR=1948

    # NOAA state-var aggregations use MEAN. (Rainfall uses SUM, but that's
    # the chirps subcommand.)
    local MONTH_OP="monmean" SEAS_OP="seasmean" ANNUAL_OP="yearmean"
    local DEKAD_OP="mean"   PENTAD_OP="mean"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --var)        VAR="$2";          shift 2 ;;
            --level)      LEVEL="$2";        shift 2 ;;
            --start)      START_YEAR="$2";   shift 2 ;;
            --end)        END_YEAR="$2";     shift 2 ;;
            --aggr)       AGGREGATIONS="$2"; shift 2 ;;
            --plot)       LAUNCH_PLOT="$2";  shift 2 ;;
            --lat)        USER_LAT="$2";     shift 2 ;;
            --lon)        USER_LON="$2";     shift 2 ;;
            --plot-type)  PLOT_TYPE="$2";    shift 2 ;;
            --clean-raw)  CLEAN_RAW="$2";    shift 2 ;;
            --outdir)     OUTDIR="$2";       shift 2 ;;
            --help|-h)
                sed -n '/^# Subcommand: noaa/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | head -30
                return 0 ;;
            *)  log_error "noaa: unknown option: $1"; return 1 ;;
        esac
    done

    # Surface vs pressure var (selects which NOAA URL base to use)
    if is_surface_var "$VAR"; then
        local BASE_URL="$BASE_URL_SURFACE"
        local IS_PRESSURE_LEVEL=false
    else
        local BASE_URL="$BASE_URL_DAILY"
        local IS_PRESSURE_LEVEL=true
    fi

    local RAW_DIR="${OUTDIR}/raw/${VAR}"
    local AGG_DIR="${OUTDIR}/aggregated/${VAR}"
    local PLOT_DIR="${OUTDIR}/plots/${VAR}"
    local LOG_DIR="${OUTDIR}/logs"

    mkdir -p "$RAW_DIR" "$AGG_DIR" "$PLOT_DIR" "$LOG_DIR"

    local MERGED_FILE="${AGG_DIR}/${VAR}_daily_${START_YEAR}_${END_YEAR}.nc"
    local LOG_FILE="${LOG_DIR}/pipeline_${VAR}_$(date +%Y%m%d_%H%M%S).log"

    # Tee all output to log
    exec > >(tee -a "$LOG_FILE") 2>&1

    check_common_deps

    # Resolve "all" for --start/--end
    if [[ "$START_YEAR" == "all" || "$END_YEAR" == "all" ]]; then
        log_section "Resolving 'all' year range for ${VAR}"
        if [[ "$START_YEAR" == "all" ]]; then
            START_YEAR="$DATASET_START_YEAR"
            log_info "Start year -> ${START_YEAR} (dataset start)"
        fi
        if [[ "$END_YEAR" == "all" ]]; then
            log_info "Probing server for latest available year..."
            local DETECTED_END
            DETECTED_END="$(detect_latest_available_year "$VAR")"
            if [[ -z "$DETECTED_END" ]]; then
                log_error "Could not auto-detect latest year (network issue?). Pass --end explicitly."
                exit 1
            fi
            END_YEAR="$DETECTED_END"
            log_info "End year   -> ${END_YEAR} (latest file found on server)"
        fi
    fi

    # Step 1: Download
    log_section "Step 1: Downloading ${VAR} Daily Data (${START_YEAR}-${END_YEAR})"
    local DOWNLOAD_COUNT=0 SKIP_COUNT=0 FAIL_COUNT=0
    local FAILED_YEARS=()
    for YEAR in $(seq "$START_YEAR" "$END_YEAR"); do
        local URL="${BASE_URL}/${VAR}.${YEAR}.nc"
        local OUTFILE="${RAW_DIR}/${VAR}.${YEAR}.nc"
        if [[ -f "$OUTFILE" ]]; then
            if cdo -s info "$OUTFILE" &>/dev/null; then
                log_info "Skipping ${YEAR} -- file exists and is valid."
                (( SKIP_COUNT++ )) || true
                continue
            else
                log_warn "${YEAR} file exists but appears corrupt. Re-downloading..."
                rm -f "$OUTFILE"
            fi
        fi
        log_info "Downloading ${VAR} for ${YEAR}..."
        if wget -q --timeout=60 --tries=3 --retry-connrefused \
                --progress=bar:force \
                -O "$OUTFILE" "$URL" 2>&1; then
            log_success "Downloaded ${YEAR}"
            (( DOWNLOAD_COUNT++ )) || true
        else
            log_error "Failed to download ${YEAR} from: ${URL}"
            rm -f "$OUTFILE"
            FAILED_YEARS+=("$YEAR")
            (( FAIL_COUNT++ )) || true
        fi
    done
    echo ""
    log_info "Download Summary:"
    log_info "  Downloaded : ${DOWNLOAD_COUNT}"
    log_info "  Skipped    : ${SKIP_COUNT}"
    log_info "  Failed     : ${FAIL_COUNT}"
    if [[ ${#FAILED_YEARS[@]} -gt 0 ]]; then
        log_warn "Failed years: ${FAILED_YEARS[*]}"
    fi

    local AVAIL_FILES=( "${RAW_DIR}/${VAR}".*.nc )
    if [[ ${#AVAIL_FILES[@]} -eq 0 ]]; then
        log_error "No files available to merge. Exiting."
        exit 1
    fi

    # Step 2: Merge
    log_section "Step 2: Merging Daily Files"
    if [[ -f "$MERGED_FILE" ]]; then
        log_warn "Merged file already exists: ${MERGED_FILE}"
        log_warn "Delete it manually to re-merge."
    else
        log_info "Running: cdo mergetime ..."
        cdo -O -f nc4 -z zip_6 mergetime \
            "${RAW_DIR}/${VAR}".*.nc \
            "$MERGED_FILE" || { log_error "Merge failed. Check CDO installation."; exit 1; }
        log_success "Merged -> ${MERGED_FILE}"
    fi
    log_info "Dataset info:"
    cdo info "$MERGED_FILE" 2>/dev/null | head -5 || true

    # Step 3: Pressure-level extraction (if applicable)
    log_section "Step 3: Pressure Level Extraction (${LEVEL} hPa)"
    local LEVEL_FILE="${AGG_DIR}/${VAR}_${LEVEL}hPa_daily_${START_YEAR}_${END_YEAR}.nc"
    local BASE_NC
    if $IS_PRESSURE_LEVEL; then
        if [[ -f "$LEVEL_FILE" ]]; then
            log_warn "Level file exists: ${LEVEL_FILE} -- skipping"
        else
            log_info "Extracting pressure level ${LEVEL} hPa..."
            cdo -O -f nc4 -z zip_6 sellevel,"$LEVEL" "$MERGED_FILE" "$LEVEL_FILE"
            log_success "Extracted ${LEVEL} hPa -> ${LEVEL_FILE}"
        fi
        BASE_NC="$LEVEL_FILE"
    else
        BASE_NC="$MERGED_FILE"
    fi

    # Step 4: Aggregations
    log_section "Step 4: Temporal Aggregations (${AGGREGATIONS})"
    local PREFIX="${VAR}_${LEVEL}hPa"
    IFS=',' read -ra AGGR_LIST <<< "$AGGREGATIONS"
    local AGGR_FAIL_COUNT=0
    local AGGR_FAILED_LIST=()
    for AGGR in "${AGGR_LIST[@]}"; do
        AGGR=$(echo "$AGGR" | xargs)
        local OUT_NC="${AGG_DIR}/${PREFIX}_${AGGR}_${START_YEAR}_${END_YEAR}.nc"
        if [[ -f "$OUT_NC" ]]; then
            log_warn "${AGGR} file exists: ${OUT_NC} -- skipping"
            continue
        fi
        log_info "Computing ${AGGR} aggregation..."
        local rc=0
        run_aggregation "$AGGR" "$BASE_NC" "$PREFIX" "$VAR" \
                        "$START_YEAR" "$END_YEAR" "$OUT_NC" "$AGG_DIR" || rc=$?
        if [[ $rc -eq 1 ]]; then
            AGGR_FAIL_COUNT=$((AGGR_FAIL_COUNT + 1))
            AGGR_FAILED_LIST+=("$AGGR")
        fi
    done
    if [[ $AGGR_FAIL_COUNT -gt 0 ]]; then
        log_warn "Aggregations with problems: ${AGGR_FAILED_LIST[*]}"
    fi

    # Step 4b: Optional raw-data cleanup
    if $CLEAN_RAW; then
        log_section "Step 4b: Cleaning Raw & Intermediate Data"
        if [[ $AGGR_FAIL_COUNT -gt 0 ]]; then
            log_warn "Skipping cleanup -- ${AGGR_FAIL_COUNT} aggregation(s) failed: ${AGGR_FAILED_LIST[*]}"
            log_warn "Raw data kept so you can re-run the failed aggregation(s) without re-downloading."
        else
            # Note what NOT to delete: LEVEL_FILE (pressure vars) sits at
            # ${AGG_DIR}/${VAR}_${LEVEL}hPa_daily_${START}_${END}.nc -- the
            # exact same path the "daily" aggregation writes to. It's real,
            # permanent output, so it is never touched here regardless of
            # this flag.
            local RECLAIMED
            RECLAIMED=$(du -shc "${RAW_DIR}"/*.nc "$MERGED_FILE" 2>/dev/null | tail -1 | cut -f1)
            if [[ -d "$RAW_DIR" ]]; then
                rm -f "${RAW_DIR}"/*.nc
                rmdir "$RAW_DIR" 2>/dev/null || true
                log_success "Removed raw yearly downloads: ${RAW_DIR}"
            fi
            if [[ -f "$MERGED_FILE" && "$MERGED_FILE" != "$LEVEL_FILE" ]]; then
                rm -f "$MERGED_FILE"
                log_success "Removed merged intermediate: ${MERGED_FILE}"
            fi
            log_info "Reclaimed approximately ${RECLAIMED:-unknown amount of} disk space."
            log_warn "Re-running this variable with an extended year range will require a full re-download (raw files are gone)."
        fi
    fi

    # Step 5: Generate plots (the merged Python script is self-contained,
    # so there's no helper file to write/symlink into $OUTDIR anymore).
    if $LAUNCH_PLOT; then
        log_section "Step 5: Launching Python Visualization"
        for AGGR in "${AGGR_LIST[@]}"; do
            AGGR=$(echo "$AGGR" | xargs)
            run_plot_step "$SHARED_PY" "$AGG_DIR" "$PLOT_DIR" \
                          "$VAR" "$LEVEL" "$PREFIX" \
                          "$USER_LAT" "$USER_LON" \
                          "$PLOT_TYPE" "$AGGR" "$START_YEAR" "$END_YEAR" \
                && log_success "Plot completed for ${AGGR}" \
                || log_error "Plotting failed for ${AGGR}"
        done
    else
        log_info "Skipping Python visualization (--plot false)"
        log_info "To plot manually, run:"
        echo ""
        echo "  python3 ${SHARED_PY} plot \\"
        echo "    --nc     ${AGG_DIR}/${VAR}_${LEVEL}hPa_monthly_${START_YEAR}_${END_YEAR}.nc \\"
        echo "    --var    ${VAR} \\"
        echo "    --lat    ${USER_LAT} \\"
        echo "    --lon    ${USER_LON} \\"
        echo "    --aggr   monthly \\"
        echo "    --level  ${LEVEL} \\"
        echo "    --outdir ${PLOT_DIR}"
        echo ""
    fi

    # Step 7: Upload plots to Supabase
    log_section "Step 7: Uploading Plots to Supabase"
    if [[ -f "$SHARED_PY" ]]; then
        run_upload_step "$PLOT_DIR" "$VAR" "$LEVEL" "$START_YEAR" "$END_YEAR" \
            && log_success "Supabase upload step finished" \
            || log_error "Supabase upload step failed -- check output above"
    else
        log_warn "${SHARED_PY} not found -- skipping upload step."
    fi

    # Final summary
    log_section "Pipeline Complete (NOAA)"
    echo -e "${GREEN}Variable    :${NC} ${VAR} @ ${LEVEL} hPa"
    echo -e "${GREEN}Period      :${NC} ${START_YEAR} - ${END_YEAR}"
    echo -e "${GREEN}Aggregations:${NC} ${AGGREGATIONS}"
    echo -e "${GREEN}Coordinate  :${NC} lat=${USER_LAT}, lon=${USER_LON}"
    echo -e "${GREEN}Raw data    :${NC} ${RAW_DIR}"
    echo -e "${GREEN}Aggregated  :${NC} ${AGG_DIR}"
    echo -e "${GREEN}Plots       :${NC} ${PLOT_DIR}"
    echo -e "${GREEN}Log file    :${NC} ${LOG_FILE}"
    echo ""
    log_success "All done!"
}


# =============================================================================
# Subcommand: chirps
# =============================================================================
# CHIRPS v2.0 daily global rainfall (0.25deg / p25 resolution).
#
# CRITICAL METEOROLOGICAL POINT: rainfall is an ACCUMULATIVE quantity, not
# a state variable like temperature. A daily CHIRPS value is already a
# daily TOTAL (mm/day). Period aggregations (monthly/seasonal/annual/
# dekad/pentad) here use SUM, not mean -- summing daily mm gives the
# period's total accumulated rainfall, which is the standard product
# (e.g. "monthly rainfall total"). Daily climatology/anomaly remain
# MEAN-based (the typical/actual value for a given calendar day across
# years).
run_chirps() {
    local START_YEAR="all"
    local END_YEAR="all"
    local AGGREGATIONS="daily,monthly,seasonal,annual,dekad,pentad,climatology,anomaly"
    local USER_LAT=-5.0
    local USER_LON=36.0
    local PLOT_TYPE="both"
    local LAUNCH_PLOT=true
    local CLEAN_RAW=false
    local OUTDIR="$DEFAULT_OUTDIR"
    local DATASET_START_YEAR=1981

    # Rainfall: use SUM-based aggregations everywhere it's physically
    # meaningful. Climatology/anomaly stay MEAN-based (see comment above).
    local MONTH_OP="monsum" SEAS_OP="seassum" ANNUAL_OP="yearsum"
    local DEKAD_OP="sum"   PENTAD_OP="sum"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start)      START_YEAR="$2";     shift 2 ;;
            --end)        END_YEAR="$2";       shift 2 ;;
            --aggr)       AGGREGATIONS="$2";   shift 2 ;;
            --lat)        USER_LAT="$2";       shift 2 ;;
            --lon)        USER_LON="$2";       shift 2 ;;
            --plot-type)  PLOT_TYPE="$2";      shift 2 ;;
            --plot)       LAUNCH_PLOT="$2";    shift 2 ;;
            --clean-raw)  CLEAN_RAW="$2";      shift 2 ;;
            --outdir)     OUTDIR="$2";         shift 2 ;;
            --help|-h)
                sed -n '/^# Subcommand: chirps/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | head -30
                return 0 ;;
            *)  log_error "chirps: unknown option: $1"; return 1 ;;
        esac
    done

    # CHIRPS is single-purpose: one variable, one "level" (surface).
    local VAR="precip"
    local LEVEL="sfc"

    local RAW_DIR="${OUTDIR}/raw/${VAR}"
    local AGG_DIR="${OUTDIR}/aggregated/${VAR}"
    local PLOT_DIR="${OUTDIR}/plots/${VAR}"
    local LOG_DIR="${OUTDIR}/logs"

    mkdir -p "$RAW_DIR" "$AGG_DIR" "$PLOT_DIR" "$LOG_DIR"

    log_section "CHIRPS v2.0 Rainfall Pipeline"
    log_info "Output directory: ${OUTDIR}"
    log_info "Resolution: 0.25deg (p25) | Aggregations: ${AGGREGATIONS}"

    check_common_deps

    # Resolve "all" for --start/--end
    if [[ "$START_YEAR" == "all" || "$END_YEAR" == "all" ]]; then
        log_section "Resolving 'all' year range"
        if [[ "$START_YEAR" == "all" ]]; then
            START_YEAR="$DATASET_START_YEAR"
            log_info "Start year -> ${START_YEAR} (dataset start)"
        fi
        if [[ "$END_YEAR" == "all" ]]; then
            log_info "Probing server for latest available year..."
            local DETECTED_END
            DETECTED_END="$(detect_latest_chirps_year)"
            if [[ -z "$DETECTED_END" ]]; then
                log_error "Could not auto-detect latest year (network issue?). Pass --end explicitly."
                exit 1
            fi
            END_YEAR="$DETECTED_END"
            log_info "End year   -> ${END_YEAR} (latest file found on server)"
        fi
    fi

    # Step 1: Download
    log_section "Step 1: Downloading CHIRPS Daily Rainfall (${START_YEAR}-${END_YEAR})"
    local DOWNLOAD_FAIL_COUNT=0
    for YEAR in $(seq "$START_YEAR" "$END_YEAR"); do
        local OUT_FILE="${RAW_DIR}/chirps-v2.0.${YEAR}.days_p25.nc"
        if [[ -f "$OUT_FILE" && -s "$OUT_FILE" ]]; then
            log_info "Already have ${YEAR}, skipping."
            continue
        fi
        local URL="${BASE_URL_CHIRPS}/chirps-v2.0.${YEAR}.days_p25.nc"
        log_info "Downloading ${YEAR}..."
        if wget -q --show-progress --timeout=60 --tries=3 -O "$OUT_FILE" "$URL"; then
            log_success "${YEAR} -> ${OUT_FILE}"
        else
            log_error "Failed to download ${YEAR}"
            rm -f "$OUT_FILE"
            DOWNLOAD_FAIL_COUNT=$((DOWNLOAD_FAIL_COUNT + 1))
        fi
    done
    if [[ $DOWNLOAD_FAIL_COUNT -gt 0 ]]; then
        log_warn "${DOWNLOAD_FAIL_COUNT} year(s) failed to download. Continuing with what's available."
    fi

    # Step 2: Merge + normalize dim names
    log_section "Step 2: Merging Years & Normalizing Dimensions"
    local MERGED_RAW="${AGG_DIR}/${VAR}_merged_raw_${START_YEAR}_${END_YEAR}.nc"
    local MERGED_FILE="${AGG_DIR}/${VAR}_daily_${START_YEAR}_${END_YEAR}.nc"

    if [[ -f "$MERGED_FILE" ]]; then
        log_info "Merged/normalized file already exists, skipping: ${MERGED_FILE}"
    else
        local YEAR_FILES=()
        for YEAR in $(seq "$START_YEAR" "$END_YEAR"); do
            local F="${RAW_DIR}/chirps-v2.0.${YEAR}.days_p25.nc"
            [[ -f "$F" ]] && YEAR_FILES+=("$F")
        done
        if [[ ${#YEAR_FILES[@]} -eq 0 ]]; then
            log_error "No raw files available to merge. Aborting."
            exit 1
        fi
        cdo -O -f nc4 -z zip_6 mergetime "${YEAR_FILES[@]}" "$MERGED_RAW" \
            || { log_error "Merge failed."; exit 1; }
        # CHIRPS ships with dims "latitude"/"longitude"; the rest of this
        # stack (noaa_plot.py's load_data, plot_spatial/timeseries) expects
        # "lat"/"lon", matching the NOAA reanalysis convention. Normalize
        # once here so the shared plotting code needs no CHIRPS-specific
        # branches at all.
        cdo -O -f nc4 -z zip_6 chname,latitude,lat -chname,longitude,lon "$MERGED_RAW" "$MERGED_FILE" \
            || { log_error "Dimension rename failed."; exit 1; }
        rm -f "$MERGED_RAW"
        log_success "Merged + normalized -> ${MERGED_FILE}"
    fi
    local BASE_NC="$MERGED_FILE"

    # Step 3: Verify the merged Python helper is available
    log_section "Step 3: Checking Python Helper"
    if [[ ! -f "$SHARED_PY" ]]; then
        log_warn "Merged Python helper (${SHARED_PY}) not available."
        log_warn "Aggregation will still proceed; plotting will be skipped."
        LAUNCH_PLOT=false
    fi

    # Step 4: Aggregations
    log_section "Step 4: Temporal Aggregations (${AGGREGATIONS})"
    local PREFIX="${VAR}_${LEVEL}hPa"
    IFS=',' read -ra AGGR_LIST <<< "$AGGREGATIONS"
    local AGGR_FAIL_COUNT=0
    local AGGR_FAILED_LIST=()
    for AGGR in "${AGGR_LIST[@]}"; do
        local OUT_NC="${AGG_DIR}/${PREFIX}_${AGGR}_${START_YEAR}_${END_YEAR}.nc"
        if [[ -f "$OUT_NC" ]]; then
            log_info "${AGGR} already exists, skipping: ${OUT_NC}"
            continue
        fi
        log_info "Computing ${AGGR} aggregation (sum-based where applicable -- rainfall is accumulative)..."
        local rc=0
        run_aggregation "$AGGR" "$BASE_NC" "$PREFIX" "$VAR" \
                        "$START_YEAR" "$END_YEAR" "$OUT_NC" "$AGG_DIR" || rc=$?
        if [[ $rc -eq 1 ]]; then
            AGGR_FAIL_COUNT=$((AGGR_FAIL_COUNT + 1))
            AGGR_FAILED_LIST+=("$AGGR")
        fi
    done
    if [[ $AGGR_FAIL_COUNT -gt 0 ]]; then
        log_warn "Aggregations with problems: ${AGGR_FAILED_LIST[*]}"
    fi

    # Step 4b: Optional raw-data cleanup
    if $CLEAN_RAW; then
        log_section "Step 4b: Cleaning Raw Data"
        if [[ $AGGR_FAIL_COUNT -gt 0 ]]; then
            log_warn "Skipping cleanup -- ${AGGR_FAIL_COUNT} aggregation(s) failed: ${AGGR_FAILED_LIST[*]}"
            log_warn "Raw data kept so you can re-run the failed aggregation(s) without re-downloading."
        else
            # Note: unlike the NOAA pressure-variable pipeline, MERGED_FILE
            # here is NOT the same path as the "daily" aggregation output
            # (daily's OUT_NC is "${PREFIX}_daily_...", MERGED_FILE is
            # "${VAR}_daily_..." -- missing the "_sfchPa" segment -- so
            # it's always a distinct, genuinely redundant intermediate).
            local RECLAIMED
            RECLAIMED=$(du -shc "${RAW_DIR}"/*.nc "$MERGED_FILE" 2>/dev/null | tail -1 | cut -f1)
            rm -f "${RAW_DIR}"/*.nc
            rmdir "$RAW_DIR" 2>/dev/null || true
            rm -f "$MERGED_FILE"
            log_success "Removed raw yearly downloads and merged intermediate."
            log_info "Reclaimed approximately ${RECLAIMED:-unknown amount of} disk space."
            log_warn "Re-running with an extended year range will require a full re-download."
        fi
    fi

    # Step 5: Generate plots
    if $LAUNCH_PLOT && [[ -f "$SHARED_PY" ]]; then
        log_section "Step 5: Generating Plots"
        for AGGR in "${AGGR_LIST[@]}"; do
            run_plot_step "$SHARED_PY" "$AGG_DIR" "$PLOT_DIR" \
                          "$VAR" "$LEVEL" "$PREFIX" \
                          "$USER_LAT" "$USER_LON" \
                          "$PLOT_TYPE" "$AGGR" "$START_YEAR" "$END_YEAR" \
                || log_warn "Plotting failed for ${AGGR} -- continuing."
        done
    else
        log_info "Skipping plot generation (--plot false, or merged Python helper unavailable)."
    fi

    # Step 6: Upload
    log_section "Step 6: Uploading Plots to Supabase"
    if [[ -f "$SHARED_PY" ]]; then
        run_upload_step "$PLOT_DIR" "$VAR" "$LEVEL" "$START_YEAR" "$END_YEAR" \
            && log_success "Supabase upload step finished" \
            || log_error "Supabase upload step failed -- check output above"
    else
        log_warn "${SHARED_PY} not found -- skipping upload step."
    fi

    # Final summary
    log_section "Done (CHIRPS)"
    echo -e "${GREEN}Variable    :${NC} ${VAR} (CHIRPS v2.0 rainfall, 0.25deg)"
    echo -e "${GREEN}Years       :${NC} ${START_YEAR}-${END_YEAR}"
    echo -e "${GREEN}Aggregations:${NC} ${AGGREGATIONS}"
    echo -e "${GREEN}Output dir  :${NC} ${OUTDIR}"
    echo
    echo "Aggregated files ready for the live explorer at:"
    echo "    ${AGG_DIR}/"
    echo
    echo "If plot_api.py is already running against this OUTDIR, rainfall will"
    echo "appear in its /api/meta response (and the explorer's dropdowns) on"
    echo "the next request -- no restart needed."
}


# =============================================================================
# Subcommand: all
# =============================================================================
# Loop the full catalog: NOAA pressure variables across the levels they
# actually exist at, all surface variables, and CHIRPS rainfall. The end
# state is the full set of aggregated NetCDFs the live plot API needs.
#
# Job here has shifted: since plot_api.py now generates timeseries/spatial
# plots LIVE for any lat/lon/domain the user picks on the website, this
# subcommand's real purpose is to make sure the full-record AGGREGATED
# NetCDF files exist for every variable/level you want selectable -- those
# are what plot_api.py reads from at request time. The old fixed-point
# sample PNGs are now optional -- useful for gallery thumbnails, not
# required for the live explorer to work.
run_all() {
    local START_YEAR="all"
    local END_YEAR="all"
    local AGGREGATIONS="daily,monthly,seasonal,annual"
    local LAT=-5.0
    local LON=37.0
    local PLOT_TYPE="both"
    local GENERATE_STATIC_PLOTS=true
    local CLEAN_RAW=false
    local OUTDIR=""
    local CHIRPS_AGGREGATIONS="daily,monthly,seasonal,annual,dekad,pentad,climatology,anomaly"
    local SKIP_CHIRPS=false
    local SKIP_NOAA=false

    # "all" now means: dataset start (1948 NOAA / 1981 CHIRPS) through the
    # latest year each server actually has, auto-detected per variable.
    # NOTE: --start all --end all downloads the FULL daily record per
    # variable -- expect a large first run (many GB, could take hours per
    # variable depending on your connection). Narrow with --start/--end
    # while testing, widen once you know it works.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start)              START_YEAR="$2"; shift 2 ;;
            --end)                END_YEAR="$2";   shift 2 ;;
            --aggr)               AGGREGATIONS="$2"; shift 2 ;;
            --chirps-aggr)        CHIRPS_AGGREGATIONS="$2"; shift 2 ;;
            --lat)                LAT="$2";        shift 2 ;;
            --lon)                LON="$2";        shift 2 ;;
            --plot-type)          PLOT_TYPE="$2";  shift 2 ;;
            --outdir)             OUTDIR="$2";     shift 2 ;;
            --skip-static-plots)  GENERATE_STATIC_PLOTS=false; shift ;;
            --skip-chirps)        SKIP_CHIRPS=true; shift ;;
            --skip-noaa)          SKIP_NOAA=true; shift ;;
            --clean-raw)          CLEAN_RAW=true;  shift ;;
            --help|-h)
                cat <<'USAGE'
Usage: all_agro_dataproces.sh all [OPTIONS]

Options:
  --start YYYY|all         Start year for both NOAA and CHIRPS (default: all)
  --end YYYY|all           End year for both (default: all)
  --aggr a,b,c             NOAA aggregations (default: daily,monthly,seasonal,annual)
  --chirps-aggr a,b,c      CHIRPS aggregations (default: daily,monthly,seasonal,annual,dekad,pentad,climatology,anomaly)
  --lat N, --lon E         Sample point for static plots (default: -5.0, 37.0)
  --plot-type TYPE         spatial | timeseries | both (default: both)
  --outdir PATH            Output root (default: ./NOAA)
  --skip-static-plots      Skip per-point sample PNG generation (data only)
  --skip-noaa              Skip the NOAA catalog
  --skip-chirps            Skip CHIRPS rainfall
  --clean-raw              Delete raw downloads after each var aggregates
USAGE
                return 0 ;;
            *)  log_error "all: unknown option: $1"; return 1 ;;
        esac
    done

    # Edit the COMBOS arrays below to control exactly which variable/level
    # pairs get generated. This is the full catalog NOAA actually serves
    # for this dataset (verified against the live server), not a hand-
    # picked subset.
    #
    # 1. Not every pressure variable has all 17 standard levels. NOAA's
    #    own docs: humidity (shum, rhum) only goes up to 300mb; omega
    #    only up to 100mb. Requesting e.g. shum@100 would just 404 --
    #    so levels are generated per-variable below, not as one flat
    #    list crossed with every variable.
    # 2. Surface variables are NOT simply "${var}.${year}.nc" on NOAA's
    #    server -- most carry a level suffix baked into the actual
    #    filename (e.g. air.sig995, not air). Using the wrong name
    #    silently 404s. The names below are verified; skt and prate were
    #    dropped because they don't appear in this dataset's surface
    #    catalog at all (they live in a different, Gaussian-grid
    #    product) -- add them back only after confirming their real
    #    path, not by guessing.
    #
    # IMPORTANT -- SCALE: this generates 100+ combinations. With
    # --start all --end all (the default), that's 100+ variables x
    # ~78 years of global daily data each. This is genuinely large
    # (realistically many tens of GB and a long runtime) -- trim the
    # arrays below before running unmodified if that's not what you
    # want.
    #
    # ALSO NOTE: NCEP/NCAR Reanalysis 1 stopped production, with its
    # last date March 17, 2026 (per NOAA). "--end all" will keep
    # landing on 2026 -- that's expected, not a bug; the dataset
    # simply isn't growing anymore.
    local PRESSURE_LEVELS_FULL=(1000 925 850 700 600 500 400 300 250 200 150 100 70 50 30 20 10)
    local PRESSURE_LEVELS_HUMIDITY=(1000 925 850 700 600 500 400 300)   # shum, rhum: to 300mb only
    local PRESSURE_LEVELS_OMEGA=(1000 925 850 700 600 500 400 300 250 200 150 100)  # omega: to 100mb only

    levels_for_var() {
        case "$1" in
            shum|rhum) echo "${PRESSURE_LEVELS_HUMIDITY[@]}" ;;
            omega)     echo "${PRESSURE_LEVELS_OMEGA[@]}" ;;
            *)         echo "${PRESSURE_LEVELS_FULL[@]}" ;;
        esac
    }

    local PRESSURE_VARIABLES=(air hgt omega rhum shum uwnd vwnd)

    # Surface variables: verified download names, level is a fixed label
    # (not looped) since each is inherently single-level.
    local SURFACE_COMBOS=(
        "slp:sfc"
        "pres.sfc:sfc"
        "pr_wtr.eatm:sfc"
        "air.sig995:sfc"
        "uwnd.sig995:sfc"
        "vwnd.sig995:sfc"
        "rhum.sig995:sfc"
        "omega.sig995:sfc"
    )

    local COMBOS=()
    if ! $SKIP_NOAA; then
        for v in "${PRESSURE_VARIABLES[@]}"; do
            for lvl in $(levels_for_var "$v"); do
                COMBOS+=("${v}:${lvl}")
            done
        done
        COMBOS+=("${SURFACE_COMBOS[@]}")
    fi

    local TOTAL=${#COMBOS[@]}
    local OK=0
    local FAILED=()

    # Determine effective outdir (empty -> DEFAULT_OUTDIR)
    local EFFECTIVE_OUTDIR
    if [[ -n "$OUTDIR" ]]; then
        EFFECTIVE_OUTDIR="$OUTDIR"
    else
        EFFECTIVE_OUTDIR="$DEFAULT_OUTDIR"
    fi

    echo "Running ${TOTAL} NOAA variable/level combinations (${START_YEAR}-${END_YEAR})..."
    echo "Static per-point sample plots: ${GENERATE_STATIC_PLOTS}"
    echo "Auto-clean raw data after each variable: ${CLEAN_RAW}"
    echo "Output dir: ${EFFECTIVE_OUTDIR}"
    echo "Skip CHIRPS: ${SKIP_CHIRPS}"
    echo

    if ! $SKIP_NOAA; then
        for i in "${!COMBOS[@]}"; do
            IFS=':' read -r VAR LEVEL <<< "${COMBOS[$i]}"
            local N=$((i + 1))
            echo "──────────────────────────────────────────────────────────"
            echo "[$N/$TOTAL] ${VAR} @ ${LEVEL}"
            echo "──────────────────────────────────────────────────────────"

            local ARGS=(
                noaa
                --var        "$VAR"
                --level      "$LEVEL"
                --start      "$START_YEAR"
                --end        "$END_YEAR"
                --aggr       "$AGGREGATIONS"
                --lat        "$LAT"
                --lon        "$LON"
                --plot-type  "$PLOT_TYPE"
                --plot       "$GENERATE_STATIC_PLOTS"
                --clean-raw  "$CLEAN_RAW"
                --outdir     "$EFFECTIVE_OUTDIR"
            )

            # Disable exec >>(tee) redirection in the subshell so each
            # NOAA run logs to its own file (matches original behaviour).
            if bash "$0" "${ARGS[@]}"; then
                OK=$((OK + 1))
            else
                FAILED+=("${VAR}:${LEVEL}")
                echo "!! Failed: ${VAR}:${LEVEL} -- continuing with the rest"
            fi
            echo
        done
    fi

    # CHIRPS pass
    if ! $SKIP_CHIRPS; then
        echo "──────────────────────────────────────────────────────────"
        echo "[CHIRPS] precip @ sfc"
        echo "──────────────────────────────────────────────────────────"
        local CHIRPS_ARGS=(
            chirps
            --start      "$START_YEAR"
            --end        "$END_YEAR"
            --aggr       "$CHIRPS_AGGREGATIONS"
            --lat        "$LAT"
            --lon        "$LON"
            --plot-type  "$PLOT_TYPE"
            --plot       "$GENERATE_STATIC_PLOTS"
            --clean-raw  "$CLEAN_RAW"
            --outdir     "$EFFECTIVE_OUTDIR"
        )
        if bash "$0" "${CHIRPS_ARGS[@]}"; then
            OK=$((OK + 1))
        else
            FAILED+=("precip:sfc")
            echo "!! Failed: precip:sfc (CHIRPS) -- continuing with the rest"
        fi
    fi

    echo "=============================================================="
    if ! $SKIP_NOAA; then
        echo "NOAA: ${OK}/${TOTAL} combinations completed successfully."
    fi
    if ! $SKIP_CHIRPS; then
        local CHIRPS_OK=$((OK - (TOTAL > 0 ? (TOTAL) : 0)))
        # Count CHIRPS success independently (0 or 1)
        if [[ ${#FAILED[@]} -eq 0 ]] || [[ " ${FAILED[*]} " != *" precip:sfc "* ]]; then
            echo "CHIRPS: completed successfully."
        else
            echo "CHIRPS: failed."
        fi
    fi
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo "Failed: ${FAILED[*]}"
        exit 1
    fi
    echo "=============================================================="
    echo
    echo "Aggregated NetCDF files are ready for the live explorer. Start the API with:"
    echo
    echo "    export NOAA_OUTDIR=\"${EFFECTIVE_OUTDIR}\""
    echo "    uvicorn all_python_agroproducts:app --host 0.0.0.0 --port 8000"
    echo "    # or, equivalently:"
    echo "    python3 all_python_agroproducts.py api --host 0.0.0.0 --port 8000"
    echo
    echo "Then open explorer.html (with API_BASE pointed at that server) to click"
    echo "a point or draw a region and generate a live plot."
    echo "=============================================================="
}


# =============================================================================
# Subcommand: update
# =============================================================================
# Incremental daily update.
#
# Compares the server's latest available date with the last date we've
# already aggregated (recorded in $OUTDIR/.last_update), and:
#   - If nothing new: exits quickly (zero work, ~1 second)
#   - If new data is available: downloads only the new days, computes
#     the aggregations on the new chunk, then merges them into the
#     existing aggregated files using CDO `mergetime`. This is O(new
#     days), NOT O(full history), so a daily update costs seconds-to-
#     minutes rather than hours.
#
# NOAA NCEP Reanalysis I stopped production on 2026-03-17 (per NOAA),
# so the NOAA update is effectively a no-op now. We still probe the
# server in case that changes, but don't expect any new files.
#
# CHIRPS publishes a year-to-date file daily, so each morning we pull
# the current year (only if it isn't already on disk) and append.
#
# Designed for unattended execution via cron / Task Scheduler.
#
# Usage:
#   bash all_agro_dataproces.sh update                # incremental, last source
#   bash all_agro_dataproces.sh update --sources noaa # NOAA only
#   bash all_agro_dataproces.sh update --sources chirps --outdir /data/NOAA
#   bash all_agro_dataproces.sh update --force-recompute  # ignore cache, redo
#       (mostly for testing)
#
# Cron entry (East Africa Time, runs at 07:00 daily):
#   0 7 * * * cd /path/to/improved && \
#       bash all_agro_dataproces.sh update >> logs/update.log 2>&1
run_update() {
    # Defaults
    local OUTDIR="$DEFAULT_OUTDIR"
    local SOURCES="noaa,chirps"  # comma-separated, any of: noaa, chirps
    local FORCE_RECOMPUTE=false
    local AGGREGATIONS=""        # empty = use the ones already on disk
    local NOTIFY_EMAIL=""        # optional: email on failure (requires `mail`)

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --outdir)         OUTDIR="$2";            shift 2 ;;
            --sources)        SOURCES="$2";           shift 2 ;;
            --aggr)           AGGREGATIONS="$2";      shift 2 ;;
            --force-recompute) FORCE_RECOMPUTE=true;  shift ;;
            --notify-email)   NOTIFY_EMAIL="$2";      shift 2 ;;
            --help|-h)
                cat <<'USAGE'
Usage: all_agro_dataproces.sh update [OPTIONS]

Pulls only the new days since the last successful update and merges them
into the existing aggregations. Designed to run unattended daily.

Options:
  --outdir PATH         Output root (default: ./NOAA)
  --sources a,b         Which sources to check: noaa, chirps
                        (default: noaa,chirps)
  --aggr a,b,c          Aggregations to update (default: same as the
                        existing files on disk for each var)
  --force-recompute     Ignore the .last_update cache and reprocess
                        everything new from scratch. Use for testing.
  --notify-email ADDR   Send a short failure report here (requires
                        the `mail` command)

The script records its progress in $OUTDIR/.last_update so a second
run on the same day is a no-op, and the next run only fetches days
that have appeared since the previous successful run.

Exit codes:
  0   nothing to do, or update succeeded
  1   download/aggregation failed
  2   configuration error (missing OUTDIR, etc.)
USAGE
                return 0 ;;
            *)  log_error "update: unknown option: $1"; return 1 ;;
        esac
    done

    # Validate OUTDIR exists (i.e. a full run has happened at least once)
    if [[ ! -d "$OUTDIR/aggregated" ]]; then
        log_error "OUTDIR/aggregated not found: ${OUTDIR}/aggregated"
        log_error "Run a full 'noaa', 'chirps', or 'all' pipeline first."
        return 2
    fi

    mkdir -p "${OUTDIR}/logs" "${OUTDIR}/raw" "${OUTDIR}/.state"

    local STATE_FILE="${OUTDIR}/.state/last_update"
    local LAST_RUN="never"
    [[ -f "$STATE_FILE" ]] && LAST_RUN="$(cat "$STATE_FILE")"

    log_section "Incremental update"
    log_info "OUTDIR  : ${OUTDIR}"
    log_info "Sources : ${SOURCES}"
    log_info "Last run: ${LAST_RUN}"
    log_info "Force   : ${FORCE_RECOMPUTE}"

    local START_TS
    START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local FAILED=0
    local UPDATED_VARS=()

    IFS=',' read -ra SRC_LIST <<< "$SOURCES"
    for SRC in "${SRC_LIST[@]}"; do
        SRC=$(echo "$SRC" | xargs)
        case "$SRC" in
            noaa)
                if ! _update_noaa "$OUTDIR" "$AGGREGATIONS" "$FORCE_RECOMPUTE"; then
                    FAILED=$((FAILED + 1))
                else
                    UPDATED_VARS+=("noaa")
                fi
                ;;
            chirps)
                if ! _update_chirps "$OUTDIR" "$AGGREGATIONS" "$FORCE_RECOMPUTE"; then
                    FAILED=$((FAILED + 1))
                else
                    UPDATED_VARS+=("chirps")
                fi
                ;;
            *)
                log_warn "Unknown source: '${SRC}' (skipping)"
                ;;
        esac
    done

    # Record successful run (only if everything succeeded -- don't poison
    # the cache with partial completions)
    if [[ $FAILED -eq 0 ]]; then
        echo "$START_TS" > "$STATE_FILE"
        log_success "Update complete (sources updated: ${UPDATED_VARS[*]:-none})"
    else
        log_error "Update finished with ${FAILED} source(s) failing. .last_update NOT updated."
        if [[ -n "$NOTIFY_EMAIL" ]] && command -v mail &>/dev/null; then
            mail -s "[agro-pipeline] UPDATE FAILED on $(hostname) at ${START_TS}" "$NOTIFY_EMAIL" <<<"${FAILED} of ${#SRC_LIST[@]} sources failed. See ${OUTDIR}/logs/update.log for details."
        fi
        return 1
    fi
}

# Helper: incremental NOAA update. NCEP Reanalysis I is frozen as of
# 2026-03-17, so this is effectively a probe -- it confirms the dataset
# really hasn't grown and logs the result. If NOAA ever resumes, the
# loop below is the skeleton to flesh out.
_update_noaa() {
    local OUTDIR="$1" AGGREGATIONS="$2" FORCE_RECOMPUTE="$3"
    log_section "NOAA incremental update (NCEP Reanalysis I, frozen 2026-03-17)"

    # Probe latest year on the server for one representative var.
    # If the year has advanced past 2026, we have new data and should
    # extend; otherwise, this is a no-op.
    local probe_var="shum"
    local latest
    latest="$(detect_latest_available_year "$probe_var")"
    if [[ -z "$latest" ]]; then
        log_warn "Could not probe NOAA server (network issue?). Skipping NOAA update."
        return 0
    fi

    if [[ "$latest" -gt 2026 ]]; then
        log_info "New NOAA data detected: latest year is ${latest} (was 2026)"
        log_info "Falling back to full 'noaa' subcommand for var=${probe_var} --start 2027 --end ${latest}"
        log_warn "For all other vars, run: bash $0 noaa --var <V> --level <L> --start 2027 --end ${latest}"
        # Most realistic: call into the noaa subcommand for one var.
        # Real users with many vars would write a small loop.
        bash "$0" noaa --var "$probe_var" --level 850 \
            --start 2027 --end "$latest" --aggr "${AGGREGATIONS:-daily,monthly,seasonal,annual}" \
            --outdir "$OUTDIR" --plot false --clean-raw true
        return $?
    else
        log_info "No new NOAA data (latest available year: ${latest}, dataset frozen at 2026). No-op."
        return 0
    fi
}

# Helper: incremental CHIRPS update. CHIRPS publishes the current-year
# file daily, so each morning we:
#   1. Probe whether the current year file exists and is larger than
#      the one we last downloaded (CHIRPS overwrites it with the
#      running year-to-date).
#   2. If yes: download, normalize lat/lon, run aggregations on the
#      new chunk, and `cdo mergetime` the results into the existing
#      aggregated files. This is the key savings: we don't re-run
#      on the entire history.
_update_chirps() {
    local OUTDIR="$1" AGGREGATIONS="$2" FORCE_RECOMPUTE="$3"
    log_section "CHIRPS incremental update"

    local VAR="precip"
    local LEVEL="sfc"
    local RAW_DIR="${OUTDIR}/raw/${VAR}"
    local AGG_DIR="${OUTDIR}/aggregated/${VAR}"
    local PLOT_DIR="${OUTDIR}/plots/${VAR}"
    local YEAR
    YEAR=$(date +%Y)
    local URL="${BASE_URL_CHIRPS}/chirps-v2.0.${YEAR}.days_p25.nc"
    local NEW_FILE="${RAW_DIR}/chirps-v2.0.${YEAR}.days_p25.nc"

    mkdir -p "$RAW_DIR" "$AGG_DIR" "$PLOT_DIR"

    # ── Step 1: Has the current-year file changed since we last saw it? ──
    # We use HTTP Content-Length as a cheap "is there new data?" probe.
    # If the file is brand new, Content-Length is the full year-to-date
    # size. If it's been refreshed, the length grows monotonically.
    local SERVER_SIZE
    SERVER_SIZE=$(curl -sIL --max-time 20 "$URL" | awk -v IGNORECASE=1 '/^content-length:/ {print $2}' | tr -d '\r' | tail -1)
    if [[ -z "$SERVER_SIZE" ]]; then
        log_warn "Could not probe CHIRPS server for current year. Skipping."
        return 0
    fi
    local LOCAL_SIZE=0
    [[ -f "$NEW_FILE" ]] && LOCAL_SIZE=$(stat -c%s "$NEW_FILE" 2>/dev/null || echo 0)

    log_info "CHIRPS current year (${YEAR}): server=${SERVER_SIZE} bytes, local=${LOCAL_SIZE} bytes"

    if ! $FORCE_RECOMPUTE && [[ -f "$NEW_FILE" ]] && [[ "$SERVER_SIZE" == "$LOCAL_SIZE" ]]; then
        log_info "Local file is already up-to-date (sizes match). No-op."
        return 0
    fi

    # ── Step 2: Download the refreshed year-to-date file ──────────────────
    log_info "Downloading refreshed ${YEAR} file..."
    if ! wget -q --show-progress --timeout=60 --tries=3 -O "$NEW_FILE" "$URL"; then
        log_error "Download failed. Skipping CHIRPS update."
        rm -f "$NEW_FILE"
        return 1
    fi
    log_success "Downloaded $(stat -c%s "$NEW_FILE") bytes"

    # ── Step 3: Normalize dims ───────────────────────────────────────────
    local NORM_FILE="${AGG_DIR}/${VAR}_days_p25_${YEAR}_normalized.nc"
    cdo -O -f nc4 -z zip_6 chname,latitude,lat -chname,longitude,lon \
        "$NEW_FILE" "$NORM_FILE" || { log_error "Dimension rename failed."; return 1; }

    # ── Step 4: Determine which aggregations to refresh ──────────────────
    # If user didn't pass --aggr, infer from existing files. That's safer
    # than re-aggregating the whole history with a new aggr the user
    # didn't have before.
    if [[ -z "$AGGREGATIONS" ]]; then
        AGGREGATIONS=$(ls "${AGG_DIR}/${VAR}_${LEVEL}hPa_"*.nc 2>/dev/null \
            | sed -E "s|.*_${LEVEL}hPa_||; s|_[0-9]{4}_[0-9]{4}\.nc||" \
            | sort -u | paste -sd, -)
        if [[ -z "$AGGREGATIONS" ]]; then
            log_warn "No existing aggregations to extend; falling back to defaults"
            AGGREGATIONS="daily,monthly,seasonal,annual"
        fi
    fi
    log_info "Aggregations to extend: ${AGGREGATIONS}"

    # Use sum-based operators (rainfall is accumulative)
    local MONTH_OP="monsum" SEAS_OP="seassum" ANNUAL_OP="yearsum"
    local DEKAD_OP="sum"   PENTAD_OP="sum"

    local PREFIX="${VAR}_${LEVEL}hPa"

    # ── Step 5: Compute aggregations on the new chunk, then merge ────────
    IFS=',' read -ra AGGR_LIST <<< "$AGGREGATIONS"
    for AGGR in "${AGGR_LIST[@]}"; do
        AGGR=$(echo "$AGGR" | xargs)
        local NEW_OUT="${AGG_DIR}/${PREFIX}_${AGGR}_${YEAR}_chunk.nc"
        local rc=0
        run_aggregation "$AGGR" "$NORM_FILE" "$PREFIX" "$VAR" "$YEAR" "$YEAR" "$NEW_OUT" "$AGG_DIR" || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Failed to compute ${AGGR} for ${YEAR} chunk -- skipping"
            rm -f "$NEW_OUT"
            continue
        fi

        # Find existing aggregated file(s) for this var/level/aggr
        # (there may be more than one if a previous run used a different
        # year range). We merge into the most recent one and keep going.
        local EXISTING
        EXISTING=$(ls "${AGG_DIR}/${PREFIX}_${AGGR}_"*.nc 2>/dev/null \
            | grep -v "_chunk" \
            | sort -t_ -k6,6n -k7,7n | tail -1)

        if [[ -z "$EXISTING" ]]; then
            # No existing file -- this chunk becomes the canonical one,
            # just rename it
            log_info "No existing ${AGGR} file; promoting chunk to canonical"
            mv "$NEW_OUT" "${AGG_DIR}/${PREFIX}_${AGGR}_${YEAR}_${YEAR}.nc"
        else
            # Merge: append the new chunk to the existing file
            local MERGED="${AGG_DIR}/${PREFIX}_${AGGR}_merged_tmp.nc"
            local EXISTING_START EXISTING_END
            EXISTING_START=$(echo "$EXISTING" | sed -E 's/.*_([0-9]{4})_[0-9]{4}\.nc/\1/')
            EXISTING_END=$(echo "$EXISTING"   | sed -E 's/.*_[0-9]{4}_([0-9]{4})\.nc/\1/')

            # For aggregations that are MEAN-based (climatology), simple
            # mergetime isn't mathematically correct -- it'd re-average
            # the mean. The original 'chirps' subcommand skips those for
            # chunked updates; same here. For sum-based monthly/seasonal/
            # annual/daily/dekad/pentad, mergetime is correct.
            case "$AGGR" in
                monthly|seasonal|annual|daily|dekad|pentad)
                    if cdo -O -f nc4 -z zip_6 mergetime "$EXISTING" "$NEW_OUT" "$MERGED"; then
                        local NEW_END
                        NEW_END=$(cdo -s showtimestamp "$NEW_OUT" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d '-' | cut -c1-4)
                        [[ -z "$NEW_END" ]] && NEW_END="$YEAR"
                        mv "$MERGED" "${AGG_DIR}/${PREFIX}_${AGGR}_${EXISTING_START}_${NEW_END}.nc"
                        # If the old filename has a different end year, drop it
                        if [[ "$EXISTING" != "${AGG_DIR}/${PREFIX}_${AGGR}_${EXISTING_START}_${NEW_END}.nc" ]]; then
                            rm -f "$EXISTING"
                        fi
                        log_success "Extended ${AGGR}: ${EXISTING_START} → ${NEW_END}"
                    else
                        log_error "Failed to merge ${AGGR} chunk; leaving existing file untouched"
                        rm -f "$MERGED"
                    fi
                    ;;
                climatology|anomaly)
                    # These need full re-computation -- skip on incremental
                    log_warn "Skipping ${AGGR} on incremental update (needs full re-compute). Run 'chirps' for a full refresh."
                    ;;
            esac
            rm -f "$NEW_OUT"
        fi
    done

    rm -f "$NORM_FILE"
    log_success "CHIRPS incremental update done"
    return 0
}


# =============================================================================
# Dispatch
# =============================================================================
case "$SUBCOMMAND" in
    noaa)   run_noaa   "$@" ;;
    chirps) run_chirps "$@" ;;
    all)    run_all    "$@" ;;
    update) run_update "$@" ;;
esac
