# Network History design

A long-term network traffic history for the Network tab, in the spirit of
NetLimiter's Long-term Stats and Connection History and iStat Menus' network
history window, rendered in this app's own design language. Branch:
`feature/network-history`.

## Why this feature

The Network tab today is live-only. System-wide download/upload rates are
persisted (`system_samples.net_in/net_out`, v6) and the Dashboard charts them
over the shared `HistoryWindow` range, but the Network page itself shows only an
in-memory trail, and none of the following exists anywhere:

- Cumulative transferred amounts ("this week: 43 GB down") as first-class
  figures. The database stores rates only; totals must be integrated.
- Per-app cumulative usage over time (what NetLimiter's Stats window is).
- Per-interface breakdown ("via Wi-Fi vs Ethernet over the month").
- Connection history: which remote hosts each app talked to, how much, when.

## What the OS exposes (verified)

All findings below were verified by reading this repo's readers and by running
`nettop` on the target platform (macOS 26, arm64).

### 1. System totals, `getifaddrs`, no privilege (already used by `NetworkReader`)

`NetworkReader` walks per-interface 32-bit byte counters on every fast tick and
differences them into in/out rates for the `en*` aggregate
(`Sources/MacPerfMonitorCore/System/NetworkReader.swift`). The per-interface
counter snapshot already exists internally (`InterfaceSnapshot`), so per-interface
accounting needs exposure, not a new data source.

### 2. Per-app, `nettop -P`, no privilege (already used by `NetworkProcessReader`)

`NetworkProcessReader` runs `nettop -P -x -J bytes_in,bytes_out -L 1` on a
background queue and differences cumulative per-PID `bytes_in`/`bytes_out`
snapshots into rates (`Sources/MacPerfMonitorCore/System/NetworkProcessReader.swift`).
The two directions are parsed separately and combined into one rate downstream.
Cost: one nettop run per refresh (tens of ms to seconds); opt-in today via the
"Track per-app network usage" toggle (`trackPerAppNetwork`).

### 3. Per-connection, `nettop -m tcp`, no privilege (new)

`nettop -m tcp -x -L 1` (without `-P`) prints one row per TCP connection with
`local:port<->remote:port`, interface, state, and cumulative
`bytes_in`/`bytes_out`, grouped under per-process rows. Verified sample:

```
tcp4 192.168.1.219:49853<->17.57.146.57:5223, en0, Established, 5294615, 704582, ...
```

UDP: `nettop -m udp` shows local endpoints; an unconnected UDP socket has no
remote, so remote attribution is TCP (and connect()ed UDP) only. Listen rows
carry no counters. This is the practical ceiling without a NetworkExtension
system extension, which this design deliberately avoids (approval, notarization
and entitlement cost far exceed the value for a monitoring feature).

### 4. Reverse DNS and geolocation

Reverse DNS via `getnameinfo` works unprivileged; it must be lazy and cached
(resolving hundreds of remote IPs at collection cadence would dominate the
reader). Offline geolocation uses MaxMind GeoLite2 `.mmdb`. GeoLite2's EULA
forbids redistributing the database, so it cannot live in the repo or the
package: it is fetched at build time (or by the user from Settings) with a
license key, and every consumer degrades gracefully when it is absent. The repo
already has the fetch-and-verify pattern (`Scripts/publishGlossary.sh`,
`checks/manifest.json.sig`).

## Attribution model

Three granularities, one source of truth each:

| Granularity | Source | Identity |
| --- | --- | --- |
| System | `NetworkReader` rates on `SystemSample` | none (machine) |
| Interface | `NetworkReader` per-interface deltas | BSD name (`en0`) |
| Per app | `NetworkProcessReader` per-PID in/out rates | `processes` row (pid + start_time), rolled up by executable/bundle at query time like `GroupHistory` |
| Per connection | new `ConnectionHistoryReader` | process row + remote ip + remote port |

Amounts (bytes) are always produced by time-integrating rates, never by
persisting raw counter snapshots: the readers already own counter-wrap and
reset handling, and the rollup pipeline already computes exact time weights
(`Retention.swift` weights every row by the dt it was in effect, so
`SUM(rate * dt)` per bucket is the transferred amount, exact up to tick
resolution).

## Data model and storage

Two migrations, following the established `Schema.vN` ALTER pattern
(`Sources/MacPerfMonitorCore/Persistence/Database.swift`). All new aggregate
columns are `NOT NULL DEFAULT 0` so pre-existing rows stay valid.

### v16: byte totals on existing tiers

```sql
-- raw: keep the direction split the readers already have
ALTER TABLE process_samples ADD COLUMN net_in  REAL NOT NULL DEFAULT 0;
ALTER TABLE process_samples ADD COLUMN net_out REAL NOT NULL DEFAULT 0;
-- net_total stays (in + out); zero for rows older than v16's split

-- per-bucket transferred amounts, system tier
ALTER TABLE system_minute ADD COLUMN net_in_sum  REAL NOT NULL DEFAULT 0;
ALTER TABLE system_minute ADD COLUMN net_out_sum REAL NOT NULL DEFAULT 0;
ALTER TABLE system_hour  ADD COLUMN net_in_sum  REAL NOT NULL DEFAULT 0;
ALTER TABLE system_hour  ADD COLUMN net_out_sum REAL NOT NULL DEFAULT 0;

-- per-bucket transferred amounts, process tier
ALTER TABLE process_minute ADD COLUMN net_in_sum  REAL NOT NULL DEFAULT 0;
ALTER TABLE process_minute ADD COLUMN net_out_sum REAL NOT NULL DEFAULT 0;
ALTER TABLE process_hour  ADD COLUMN net_in_sum  REAL NOT NULL DEFAULT 0;
ALTER TABLE process_hour  ADD COLUMN net_out_sum REAL NOT NULL DEFAULT 0;
```

`Retention` rollup SQL gains the matching terms:

- system: `SUM(net_in * dt)`, `SUM(net_out * dt)` (system rows are dense, dt is
  the row spacing as in the existing weighted sums).
- process: `SUM(net_in * dt)`, `SUM(net_out * dt)` using the existing LEAD-over
  dt subquery; minute-to-hour rollup sums the minute tier's `*_sum` directly.

Note the raw tier trims after 2 h, so per-app amounts for anything older than
that come exclusively from the minute (7 d) and hour (90 d) tiers. That is the
same trade every other metric here already makes.

`SampleStore.insertChanged` writes the two new raw columns; `ProcessSample`
gains `networkInBytesPerSec`/`networkOutBytesPerSec` (defaulting 0 so existing
call sites build) alongside `networkBytesPerSec`.

### v17: interfaces and connections

```sql
CREATE TABLE interface_stats (
    interface TEXT NOT NULL,
    bucket REAL NOT NULL,
    net_in_sum REAL NOT NULL DEFAULT 0,
    net_out_sum REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (interface, bucket)
);

CREATE TABLE connection_stats (
    process_id INTEGER NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    remote_ip TEXT NOT NULL,
    remote_port INTEGER NOT NULL,
    day INTEGER NOT NULL,          -- UTC day number, floor(ts / 86400)
    net_in_sum REAL NOT NULL DEFAULT 0,
    net_out_sum REAL NOT NULL DEFAULT 0,
    first_transfer REAL NOT NULL,
    last_transfer REAL NOT NULL,
    PRIMARY KEY (process_id, remote_ip, remote_port, day)
);
CREATE INDEX idx_connection_stats_day ON connection_stats(day);
```

- `interface_stats` is fed from `NetworkReader`'s per-interface deltas, written
  on the existing persist cadence into the current minute bucket, rolled up
  minute-to-hour by summation, and trimmed by `Retention` alongside the other
  tiers. Interface names are an unbounded-ish set but small in practice
  (single digits); no dimension table.
- `connection_stats` accumulates daily upserts from the connection reader's
  deltas (UPSERT adding deltas, clamping negative wrap to 0, updating
  first/last transfer). Deletes cascade through `processes`, which already
  cleans up exited processes' rows via retention.
- Retention: connection stats ride the hour tier's window (90 d default);
  interface stats the same. The size cap trims them finest-first like the rest.

## Queries (SampleStore extension, `NetworkHistory.swift`)

- `networkTotals(window:) -> (in: UInt64, out: UInt64)`: sum of `*_sum` over the
  tier the window maps to, plus the raw remainder for sub-2 h windows.
- `networkSeries(window:bucketCount:) -> [NetworkHistoryPoint]`: bucketed in/out
  amounts for the chart (minute tier for 24 h-style periods, hour tier beyond).
- `networkAppTotals(window:limit:) -> [NetworkAppUsage]`: per-app in/out joined
  through `processes` (executable_path, bundle_id, display name), ordered by
  total, following the `aggregateConsumers` covering-index pattern
  (`HistoryQuery.swift`).
- `networkAppSeries(identity:window:) -> [NetworkHistoryPoint]`: one app's
  timeline for the expanded row.
- `networkInterfaceTotals(window:)` / `networkInterfaceSeries(name:window:)`.
- `connectionTotals(window:limit:) -> [ConnectionUsageRow]`: remote ip + app
  groups with in/out, first/last transfer, over the window.

A dedicated `NetworkHistoryPeriod` enum (last hour / 24 h / 7 d / 30 d / all)
lives in the feature, mapping to tiers; the shared `HistoryWindow` enum is not
touched because every page's picker iterates `HistoryWindow.allCases`, and the
network page's periods (30 d, all) intentionally exceed it. "All" means "all
retained history" (the hour tier's floor), which is the honest maximum.

## The UI

One new surface on the Network tab, plus small additions elsewhere. Everything
reuses existing chrome: the Dashboard-style bordered panel, the segmented range
picker with `.historyRangeGate()`, `TrendChart`/`TrendModel`, `ByteFormat`,
`NetworkStyle` (green download / red upload, the app's directional colors; the
reference screenshot's blue/red is iStat's language, not ours), and
`ProcessIconProvider` for app icons.

### Network History panel (Network tab)

- Header row: period picker (segmented: Hour, 24 h, 7 d, 30 d, All), interface
  picker (All interfaces + recorded names), CSV export, Clear.
- Chart: in/out over the period as two `TrendSeries` (filled download band,
  upload line, matching `NetworkChart`), with a Total / Per-app segmented
  toggle; per-app mode stacks the top apps (colored per app like the groups
  charts) plus an Other remainder.
- Totals read-out: "X down, Y up over the period" in the panel header area.
- Per-app table: icon, app name, executable/bundle id, Data In, Data Out, share
  bar; expandable rows (disclosure) revealing the app's timeline chart and, when
  connection tracking is on, its top remote hosts.
- Right sidebar (wide layout): total down/up and per-app share list with
  percent bars, matching the screenshot's information design in the app's
  visual language. Collapses under the table at narrow widths.
- Empty states: logging disabled → `HistoryRangeGate`-style enable prompt;
  per-app history empty → point at the per-app tracking toggle.

### Connection history section

- Below the per-app table, opt-in: toggle "Record connection history" (own
  defaults key, `recordConnectionHistory`, default off) + caption explaining
  the extra nettop run and its cost.
- Table: remote IP (hostname when resolved), port, app, Data In, Data Out,
  first/last transfer, country flag (when the geo database is present).
- Reverse DNS resolves lazily per visible row on a background queue, cached
  in-process (LRU, a few hundred entries); never on the collection path.

### Settings

- New Network section entries: "Record connection history" (off by default),
  and, if the geo database is not installed, a "Download geolocation database"
  action with a license-key field; caption states what leaves the machine
  (the IP is resolved locally; the MaxMind download is the only network call).
- Clear network history lives on the History panel (confirmation dialog), not
  Settings: it is a data action, not a preference.

### CSV export

Follows the `TraceExportSheet` export flow (save panel, then serialize on a
background queue). Exports the current period's per-app table (app, executable,
bundle id, in, out) and, when expanded, per-period series. Connection history
exports its own table with the same mechanism.

## Risks and fallbacks

- **nettop cost (per-connection reader).** One more nettop run per 30 s cadence.
  Mitigation: own background queue, adaptive pacing and hard timeout copied from
  `NetworkProcessReader`; runs only while the toggle is on; the sampler's hot
  path never blocks on it (same cache pattern, `latestDeltas()`).
- **Counter wrap/reset on connections.** Flows close and counters vanish; the
  reader clamps negative deltas to 0 (`CPUMath.delta` semantics) and writes the
  last observed delta when a connection disappears between samples.
- **Rate integration error.** Totals are tick-resolution integrals; gated raw
  writes (insertChanged) drop flat rows, but the per-bucket heartbeat row keeps
  dt coverage complete, so minute-tier integrals stay honest. Documented as
  "approximate at sub-minute granularity" nowhere in the UI: the figure is
  exact at bucket resolution, which is what every period shows.
- **GeoLite2 absence.** All geo columns/flags degrade to hidden; no empty-state
  noise. The feature never blocks on the download.
- **Per-app tracking off.** Per-app amounts accrue only while tracking is on;
  older-than-2 h gaps read as zero, not as "no traffic". The panel captions this
  explicitly ("per-app history begins when tracking is enabled").
- **PID churn.** Attribution goes through `processes` (pid + start_time), which
  the sampler already resolves; queries group by executable/bundle so a
  relaunched app's usage aggregates under one row, matching `GroupHistory`.

## Phasing

1. **Foundation (v16):** raw split columns, rollup sums, `NetworkSample`
   direction split, insert path, queries + unit tests (`NetworkHistoryTests`,
   rollup round-trip in the `PersistenceTests` fixture style).
2. **History UI:** Network History panel: period picker, totals, system and
   per-app chart, per-app table with expandable rows, share sidebar, CSV,
   localization, Settings captions.
3. **Interfaces (v17a):** `interface_stats`, reader exposure of per-interface
   deltas, interface picker, per-interface series.
4. **Connections (v17b):** `ConnectionHistoryReader`, `connection_stats`,
   toggle, connection table with lazy reverse DNS.
5. **Geo:** `Scripts/fetch-geolite.sh`, minimal `.mmdb` reader in Core (the repo
   takes no new dependency for this; the format is a simple B-tree), country
   column + flag, Settings download flow.
6. **Verification:** unit suite, full build (`swift build`), UI smoke test on
   the running app, CHANGELOG entry under a new Unreleased/Added section.

## Open questions

- Connection-history cadence: 30 s fixed vs following the refresh dial (floor
  30 s). Default proposal: fixed 30 s, independent of the dial.
- Should the Network History panel also appear as a standalone window (like the
  screenshot) or stay on the tab? Default proposal: tab-only for now; the view
  is built self-contained so promoting it to a window later is mechanical.
- Retention for `connection_stats`: ride the 90 d hour window (proposed) or a
  shorter dedicated window?
