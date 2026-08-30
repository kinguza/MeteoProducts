-- =============================================================================
-- Supabase schema for Agromet / NOAA / CHIRPS plot products
-- =============================================================================
-- Run this in the Supabase SQL Editor (Project -> SQL Editor -> New query).
--
-- What this sets up
-- -----------------
-- 1. The `noaa-plots` storage bucket (public read so the gallery can <img>
--    the public_url directly).
-- 2. The `noaa_products` table that the upload subcommand
--    (all_python_agroproducts.py upload ...) writes one row per PNG into,
--    and that gallery.html queries to render its thumbnail grid.
-- 3. Row Level Security so anonymous website visitors can SELECT rows
--    (read-only, RLS-filtered) but only the service_role key (the one the
--    upload script uses) can write.
-- 4. Indexes on every column the gallery filters on, so even with tens of
--    thousands of rows the dropdowns stay snappy.
-- 5. A `var_labels` view that maps raw var codes (shum, air.sig995, ...)
--    to their human-readable long names, so the gallery doesn't have to
--    hard-code the mapping in JavaScript.
--
-- This script is fully idempotent: re-running it is safe and just no-ops
-- the parts that already exist.
-- =============================================================================


-- =============================================================================
-- 1. STORAGE BUCKET
-- =============================================================================
-- The bucket is public so <img src="public_url"> works directly in the
-- static site. Browsers don't need any Supabase auth to view the images.
insert into storage.buckets (id, name, public)
values ('noaa-plots', 'noaa-plots', true)
on conflict (id) do nothing;


-- =============================================================================
-- 2. RLS POLICIES ON storage.objects
-- =============================================================================
-- Browsers (anon) need to be able to read PNGs from this bucket so the
-- gallery can render them. Only the service_role key (used by the upload
-- script on the server, NEVER exposed in the static site) can write.

-- Public read: anyone can SELECT from the bucket
drop policy if exists "Public read noaa-plots" on storage.objects;
create policy "Public read noaa-plots"
    on storage.objects for select
    using (bucket_id = 'noaa-plots');

-- Uploads/updates: only service_role
drop policy if exists "Service role can upload noaa-plots" on storage.objects;
create policy "Service role can upload noaa-plots"
    on storage.objects for insert
    to service_role
    with check (bucket_id = 'noaa-plots');

drop policy if exists "Service role can update noaa-plots" on storage.objects;
create policy "Service role can update noaa-plots"
    on storage.objects for update
    to service_role
    using (bucket_id = 'noaa-plots');

drop policy if exists "Service role can delete noaa-plots" on storage.objects;
create policy "Service role can delete noaa-plots"
    on storage.objects for delete
    to service_role
    using (bucket_id = 'noaa-plots');


-- =============================================================================
-- 3. METADATA TABLE
-- =============================================================================
-- One row per PNG that the upload subcommand wrote to the bucket.
-- Columns are designed to match exactly what all_python_agroproducts.py
-- writes in the `upload` subcommand (see the `row = {...}` dict).
create table if not exists public.noaa_products (
    id           uuid primary key default gen_random_uuid(),

    -- Variable identifier (e.g. "shum", "uwnd", "air.sig995", "precip").
    var          text not null,

    -- Human-friendly level label as used by the pipeline: "850", "sfc",
    -- "sig995", "eatm", etc. Always set -- a row with NULL level_label
    -- is meaningless in this catalog.
    level_label  text not null,

    -- Numeric pressure level in hPa, or NULL for surface/single-level
    -- variables (slp, pres.sfc, pr_wtr.eatm, *.sig995, precip).
    -- The upload subcommand sets this via:
    --   int(args.level) if args.level.isdigit() else None
    level_hpa    integer,

    -- Temporal aggregation: daily, monthly, seasonal, annual,
    -- dekad, pentad, climatology, anomaly. Stored as plain text so
    -- the pipeline can add new aggregation names without a migration.
    aggr         text not null,

    -- Plot type as parsed from the filename: spatial, timeseries, hovmoller.
    plot_type    text not null,

    -- Latitude/longitude for time-series and hovmoller plots, or NULL for
    -- global spatial maps. Stored in degrees (NOT the "20.0N_80.0E" string
    -- form used in filenames -- the upload subcommand parses that already).
    lat          double precision,
    lon          double precision,

    -- Year span the underlying aggregated NetCDF covers. For "shum 850
    -- monthly 1990-2020", start_year=1990 and end_year=2020. The gallery
    -- uses these for its "From year / To year" filters.
    start_year   integer,
    end_year     integer,

    -- Storage path inside the bucket, e.g. "shum/shum_850hPa_monthly_spatial.png".
    -- UNIQUE so re-uploading the same file (upsert on file_path) updates
    -- the existing row rather than creating a duplicate.
    file_path    text not null unique,

    -- Resolved public URL for direct <img src="..."> use. The upload
    -- subcommand gets this from supabase.storage.get_public_url().
    public_url   text not null,

    -- File size in bytes (informational; useful for showing "23.4 MB"
    -- badges in the gallery if you want to add that later).
    file_size    bigint,

    -- Server-side creation timestamp. Set automatically on insert.
    -- The gallery sorts by this DESC so the newest plots appear first.
    created_at   timestamptz not null default now(),

    -- ── Constraints ────────────────────────────────────────────────────
    -- The gallery and the live API both rely on a small known vocabulary
    -- for plot_type and aggr. Check constraints catch typos early instead
    -- of letting a misspelled row sit in the DB confusing the filters.
    constraint chk_plot_type check (plot_type in ('spatial','timeseries','hovmoller')),
    constraint chk_aggr      check (aggr in (
        'daily','monthly','seasonal','annual',
        'dekad','pentad','climatology','anomaly'
    )),
    -- level_hpa, when set, must be one of the standard pressure levels
    -- actually used by the pipeline. (NULL is fine for surface vars.)
    constraint chk_level_hpa check (
        level_hpa is null or level_hpa in (
            10,20,30,50,70,100,150,200,250,300,400,500,600,700,850,925,1000
        )
    ),
    -- A bounding box / point row needs its lat/lon to be sane.
    constraint chk_lat check (lat is null or (lat between -90 and 90)),
    constraint chk_lon check (lon is null or (lon between -180 and 180)),
    -- Year range sanity (start <= end when both set)
    constraint chk_year_range check (
        start_year is null or end_year is null or start_year <= end_year
    )
);

-- Forward-compat: if you ran an earlier version of this schema that
-- didn't have `level_label`, add it as nullable, then the table-level
-- NOT NULL will be applied once the column is backfilled. This block
-- is a no-op if the column already exists.
alter table public.noaa_products
    add column if not exists level_label text;

-- Now enforce NOT NULL on level_label (safe because we just added it
-- with no rows yet, or because existing rows must have it filled in).
-- If you have legacy rows with NULL level_label, run this manually
-- after backfilling them:
--   update public.noaa_products set level_label = '' where level_label is null;
--   alter table public.noaa_products alter column level_label set not null;

-- A second one: file_size was added in a later version. Same pattern.
alter table public.noaa_products
    add column if not exists file_size bigint;


-- =============================================================================
-- 4. INDEXES
-- =============================================================================
-- The gallery filters by (var, level_label, aggr, plot_type) and filters
-- by year overlap. With the catalog growing to ~16 PNGs per
-- (var, level, aggr) combo, the table will easily hit 10K+ rows for a
-- full run. These indexes keep the dropdowns and filter queries fast.

-- Composite index covering the most common gallery query:
--   WHERE var = $1 AND level_label = $2 AND aggr = $3 AND plot_type = $4
create index if not exists idx_noaa_products_filter
    on public.noaa_products (var, level_label, aggr, plot_type);

-- Year-overlap queries (the gallery does p.start_year <= $hi AND p.end_year >= $lo).
-- A btree on (start_year, end_year) lets Postgres use index-only scans
-- for the year range check.
create index if not exists idx_noaa_products_years
    on public.noaa_products (start_year, end_year);

-- created_at DESC index: the gallery sorts by this so the newest uploads
-- appear first. DESC matches the access pattern exactly.
create index if not exists idx_noaa_products_created_at
    on public.noaa_products (created_at desc);


-- =============================================================================
-- 5. ROW LEVEL SECURITY
-- =============================================================================
-- The gallery runs in the user's browser and authenticates with the anon
-- (public) key, which under RLS means "untrusted user". The RLS policies
-- below ensure that anon can only SELECT (no writes, no deletes) and that
-- only the service_role key can modify data.
alter table public.noaa_products enable row level security;

-- Anon SELECT: full read access. The table holds no secrets -- just
-- metadata and public image URLs -- so this is safe to expose.
drop policy if exists "Public read noaa_products" on public.noaa_products;
create policy "Public read noaa_products"
    on public.noaa_products for select
    to anon
    using (true);

-- Service role ALL: the upload script (running server-side with the
-- SUPABASE_SERVICE_KEY env var) needs to insert/update/delete rows as
-- files change. Service role bypasses RLS by default, but we add the
-- explicit policies for clarity and to make the access pattern auditable.
drop policy if exists "Service role write noaa_products" on public.noaa_products;
create policy "Service role write noaa_products"
    on public.noaa_products for all
    to service_role
    using (true)
    with check (true);


-- =============================================================================
-- 6. HELPER VIEW: human-readable variable labels
-- =============================================================================
-- gallery.html currently hard-codes the VAR_LABELS map. To keep the
-- mapping in one place (and let the server update it without touching
-- the HTML), we expose it as a view. The static site can query it
-- alongside noaa_products if you want; the current gallery doesn't, but
-- this is here for future use.
--
-- Note: views under RLS inherit the underlying table's policy. Since
-- noaa_products is selectable by anon, this view is too. The view only
-- reads static metadata (no per-row RLS needed).
create or replace view public.var_labels as
select * from (values
    ('shum',         'Specific Humidity',          'kg/kg',   'YlGnBu'),
    ('uwnd',         'U-Wind (Zonal)',             'm/s',     'RdBu_r'),
    ('vwnd',         'V-Wind (Meridional)',        'm/s',     'RdBu_r'),
    ('air',          'Air Temperature',            'K',       'RdYlBu_r'),
    ('omega',        'Vertical Velocity',          'Pa/s',    'RdBu'),
    ('hgt',          'Geopotential Height',        'm',       'viridis'),
    ('rhum',         'Relative Humidity',          '%',       'YlGnBu'),
    ('prate',        'Precipitation Rate',         'kg/m2/s', 'Blues'),
    ('slp',          'Sea Level Pressure',         'Pa',      'RdYlBu_r'),
    ('pres.sfc',     'Surface Pressure',           'Pa',      'RdYlBu_r'),
    ('pr_wtr.eatm',  'Precipitable Water',         'kg/m2',   'YlGnBu'),
    ('air.sig995',   'Surface Air Temperature',    'K',       'RdYlBu_r'),
    ('uwnd.sig995',  'Surface U-Wind',             'm/s',     'RdBu_r'),
    ('vwnd.sig995',  'Surface V-Wind',             'm/s',     'RdBu_r'),
    ('rhum.sig995',  'Surface Relative Humidity',  '%',       'YlGnBu'),
    ('omega.sig995', 'Surface Vertical Velocity',  'Pa/s',    'RdBu'),
    ('precip',       'CHIRPS Rainfall',            'mm',      'Blues')
) as t(var, long_name, units, default_cmap);

-- Grant the same access to the view as to the underlying tables.
grant select on public.var_labels to anon, authenticated, service_role;


-- =============================================================================
-- 7. SUMMARY OF WHAT WAS CREATED
-- =============================================================================
-- After running this script, you should have:
--
--   storage.buckets:
--     - noaa-plots        (public read)
--
--   storage.objects policies:
--     - Public read noaa-plots            (anon SELECT)
--     - Service role can upload noaa-plots (service_role INSERT)
--     - Service role can update noaa-plots (service_role UPDATE)
--     - Service role can delete noaa-plots (service_role DELETE)
--
--   public.noaa_products (table):
--     Columns: id, var, level_label, level_hpa, aggr, plot_type,
--              lat, lon, start_year, end_year, file_path (unique),
--              public_url, file_size, created_at
--     Indexes: (var, level_label, aggr, plot_type),
--              (start_year, end_year),
--              (created_at DESC)
--     RLS: anon SELECT, service_role ALL
--
--   public.var_labels (view):
--     Human-readable mapping of var codes to long names, units, colormaps.
-- =============================================================================

