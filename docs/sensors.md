# Sensors

The Sensors read-out lists every figure the machine's SMC and IOReport will
give up: fan speeds, temperatures, voltages, currents, power rails, and the
energy the system has drawn since the app started. It is a port of Stats'
Sensors module (github.com/exelban/stats, MIT), which is where the key
catalogue, the grouping and the derived figures come from.

This is deliberately separate from the Temperature read-out. Temperature answers
"is this Mac hot, and is it throttling", with one headline figure and a trend.
Sensors answers "what does this machine actually report", with no editorial: 40
rows, each named and each printed.

## Where the numbers come from

**The SMC.** `SMCReader` enumerates the key list once (`#KEY`, then
`kSMCGetKeyFromIndex`) and reads any key whose name starts with `T`, `V`, `P` or
`I`: temperature, voltage, power, current. The SMC does not describe its own
keys, so a four-character code is all a raw enumeration gives you.

**The catalogue** (`SensorCatalog`) turns those codes into names. It is Stats'
table, key for key, including the per-generation splits: `Tp01` is a
performance core on M2 and on M4, and does not exist in the M5 table at all
(M5's low `Tp` keys are super cores). The running Mac's platform is resolved
from `machdep.cpu.brand_string` and the table is filtered to it before anything
is named. An unrecognised chip gets the whole table tried against its actual
key set, which is the honest fallback.

**IOReport** supplies the five power rails the SMC has no keys for on Apple
silicon: CPU, GPU, ANE, DRAM and PCI. They are "Energy Model" counters, so they
are monotonic energy: power is the difference between two samples over the
elapsed time, and the first sample has nothing to difference against.

**Derived figures**, all computed here rather than read:

| Row | How |
| --- | --- |
| Average CPU / GPU | Mean of the per-core die sensors |
| Hottest CPU / GPU | Max of the same set |
| Fastest fan | Only on a Mac with more than one fan |
| Average System Total | Accumulated watt hours divided back over the run |
| Total System Consumption | `System Total` watts integrated since the first read |

Only sensors the catalogue marks `average` feed the CPU and GPU figures: the
per-core die sensors. Package and proximity sensors measure the same heat from
further away, so folding them in would drag the average toward the case
temperature.

## What the panel leaves out

Two things, both because a list of forty rows is only useful if the rows differ
from each other:

**The unnamed keys.** Anything the catalogue could not name is read but not
listed: a four-character code with no meaning is noise. `macperfmonitor-cli
sensors --unknown` is where to go looking for them.

**The per-core sensors, by default.** A modern chip reports twenty-odd CPU and
GPU core temperatures that track each other within a degree or two, and listing
them all buries the sensors that say something distinct (the SSD, the battery,
the airflow). The averages stand in for them, and the Temperature section
heading carries a switch to expand the detail. The readings are always taken
either way: hiding them is a display choice, and the averages are computed from
the full set.

## Ordering

Rows are grouped into sections (fans, temperature, power, energy) and, inside a
section, by domain in first-appearance order, keeping the reader's order inside
each domain.

Volts and amps sit under the watts in the power section rather than heading
sections of their own: they are the two halves of the power beside them, and a
Mac reports so few of them that three headings cost more room than the rows they
introduce. A section states its unit in its heading so no row repeats it, so the
power section gives its heading unit up as soon as it holds more than one kind,
and its rows carry theirs instead. That rule is Stats', and it is what puts
"Average CPU" and "Hottest CPU" directly under the cores they summarise instead
of at the end of the section, and files the IOReport rails after the SMC power
keys rather than interleaved with them.

The reader's own order is: fans, then catalogue entries whose key is exact,
then catalogue entries whose key holds a `%` wildcard (expanded 0 through 9
against the keys that exist, with the `%` in the name replaced by a 1-based
counter), then anything left over as an unnamed reading, then the IOReport
rails, then the derived figures.

## Deviations from Stats

**Intel-era CPU and GPU keys are Intel only here.** Stats offers `TC0D`,
`TC0P`, `TG0D`, `TG0H`, `TG0P`, the Northbridge keys and the rest on every
platform. On an M5, `TG0H` ("GPU heatsink") is a live, readable SMC key holding
a frozen `34.0`: it does not move while the GPU die sensors climb fifteen
degrees under load. Stats never shows it because its SMC decoder has no `ioft`
case and the read simply fails; this app's decoder does read `ioft`, so the
placeholder has to be excluded on purpose rather than by accident. Apple
silicon has no CPU diode, no discrete GPU and no northbridge, so the honest fix
is the platform column.

**No fan control.** Stats can force a fan speed. That means writing to the SMC,
which needs a privileged helper, and this app does not do it. Fan rows are read
only: speed, and the share of the fan's rated maximum.

**No HID sensor set.** Stats can also read the `AppleSiliconSensors` HID pages
behind a preference. Those are largely the same die sensors under different
names, so they are not ported.

## Cost

The first sweep pays key discovery: a full `#KEY` enumeration with a read per
key, a few hundred milliseconds. After that the reader re-reads only the keys
that resolved, which is tens of milliseconds. Sweeps only happen when something
is watching: the panel asks while it is open, and the menu bar asks only when a
sensors read-out is actually on the bar. An app with no sensors surface in use
never touches the SMC through this path.

The IOReport subscription is filtered to the five energy channels rather than
the roughly 180 the "Energy Model" group carries.

## The menu bar read-out

Sensors is the one read-out with no single figure of its own, so the only shape
offered is Stack: the chosen sensors drawn side by side, pairs stacked into
columns, exactly as Stats' Sensors module does it. Sensors are chosen from the
check beside each row in the panel. With nothing chosen the cell falls back to
its own short title, so the item stays visible and clickable.

## Diagnostics

    macperfmonitor-cli sensors [--unknown]

prints the whole inventory grouped the way the panel groups it, which is how
the port was checked against Stats on the same machine.
