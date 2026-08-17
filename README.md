# RotVitals

Floating enemy health bars for **Grain Rot** (UE 5.7, via UE4SS).

A health bar hovers over every enemy's head, tracks them at frame rate, and
reads the live replicated health value — so it works as host or as a joining
client, and unmodded lobby mates see nothing.

## Features

- **Frame-rate tracking.** Health is read every frame, so the bar never lags a
  hit, and placement is corrected for camera motion so bars stay locked to the
  enemy while you move around them.
- **Damage-lag ghost bar.** A pale red bar drains behind the fill after a hit.
- **Hit punch.** The bar pops the instant health drops.
- **Green → amber → red** fill over a segmented track, with a drop shadow,
  a hard outline and a bone rim (gold when the enemy is enchanted).
- **Line-of-sight gated.** Bars are hidden when the enemy is behind geometry,
  and range is capped at 18 m — deliberately not a wallhack.
- **HP numbers** above the bar, switchable off.
- **Flying drones too**, which are not characters and have no health of their
  own — see below.
- Distance scaling, distance fade, and fade in/out instead of popping.

Only enemies get bars (`EHeldenCharacterType::Enemy`, plus all `AHeldenDrone`).
Players, soul vessels and friendly NPCs are ignored.

## Install

### Thunderstore (recommended)

Install **RotVitals** by Mentalize from the Grain Rot community with
Thunderstore Mod Manager or r2modman. The `GrainRot_UE4SS` dependency brings
its own UE4SS build and signatures, so there is nothing else to set up.

### Manual

Requires a manual UE4SS **experimental** install in
`Grain Rot\Helden\Binaries\Win64\`.

1. Download `RotVitals-1.0.0.zip` from [Releases](../../releases).
2. Extract it over `Grain Rot\Helden\Binaries\Win64\ue4ss\`, so you end up
   with:
   ```
   ue4ss\Mods\RotVitals\enabled.txt
   ue4ss\Mods\RotVitals\Scripts\main.lua
   ue4ss\UE4SS_Signatures\*.lua
   ```
3. Start the game. `enabled.txt` self-enables the mod — no `mods.txt` edit
   needed.

The bundled `UE4SS_Signatures` are the UE 5.7 AOB fixes from
[UE4SS issue #1228](https://github.com/UE4SS-RE/RE-UE4SS/issues/1228); without
them UE4SS fails its pattern scan on this engine version. They are harmless if
you already have them.

## Configuration

Everything is in the `CFG` block at the top of `Mods/RotVitals/Scripts/main.lua`:

| Setting        | Default | What it does                                      |
|----------------|---------|---------------------------------------------------|
| `MAX_DIST`     | 1800    | Range in uu (100 uu = 1 m) — no bars past this     |
| `FADE_DIST`    | 1300    | Bars start fading out here                         |
| `MAX_BARS`     | 16      | Most bars on screen at once (nearest enemies win)  |
| `WALL_CHECK`   | true    | Hide bars for enemies behind geometry              |
| `LOS_INTERVAL` | 0.12    | Seconds between line-of-sight traces per enemy     |
| `SHOW_NUMBERS` | true    | `42 / 118` above the bar                           |
| `HIDE_FULL_HP` | false   | Set true to only show enemies you have hurt        |
| `SEGMENTS`     | 4       | Divider ticks across the track (0 = plain bar)     |
| `DRONES`       | "host"  | Drone bars: `"host"` health, `"state"` 3-step, `"off"` none |
| `DRONE_OFFSET` | 55      | Bar height above a drone (drones have no capsule)  |
| `BAR_W` / `BAR_H` | 128 / 14 | Bar size at reference distance                  |
| `HEAD_OFFSET`  | 40      | Height above the head                              |
| `CAMERA_LEAD`  | 1.0     | One-frame camera correction — set 0 to disable     |
| `POS_SMOOTH`   | 0       | Extra screen-space smoothing, 0 = off              |

No hotkeys, no config file, no external processes, nothing written to disk.

## How it works

The HUD is a UMG overlay built from Lua at runtime. Each bar is its own nested
canvas, so moving one costs a single `SetPosition` per frame while colour and
size writes only happen when the values actually change.

Enemy intake is `NotifyOnNewObject` plus a slow catch-up sweep — no polling
loops. A round-robin range pass keeps the per-frame work to the handful of
enemies near the camera.

Bar placement does not use the engine's `ProjectWorldLocationToWidgetPosition`
directly. Everything runs from a per-frame animation-blueprint hook that fires
*before* the camera manager updates, so the engine projection places bars with
the previous frame's camera — the error scales with camera speed, which shows
up as bars swimming whenever you move. Instead the mod builds its own view
basis and projects against a camera extrapolated one frame forward. On startup
it cross-checks that maths against the engine's projection for 20 samples and
only adopts it if they agree within 4 px, otherwise it falls back and logs the
mismatch. (Measured worst-case agreement on the shipped build: 0.3 px.)

Wall occlusion uses `AController::LineOfSightTo` rather than a trace with an
`FHitResult` out-parameter, which is a known crash shape for this game under
UE4SS. `WasRecentlyRendered` alone is not sufficient — it counts shadow-pass
renders, so an enemy behind a wall casting a shadow into view still reads as
visible.

Bar maximums are only taken from `UHeldenStatsComponent.TotalStats` where
`AActor::HasAuthority()` is true. `TotalStats` is computed locally rather than
replicated — the game replicates a recipe (`ReplicatedStats`: stat names plus
level) and each machine derives the totals itself — and on a machine that does
not own the actor that derivation does not produce real numbers; every enemy
read back a flat 120 maximum on a joining client. `CurrentHealth` does
replicate. So off the host, the maximum is the highest health the mod has
observed for that enemy, which is exact for anything seen before it was hurt
and is also the only source that survives a host-side stat mod raising max
health (that raised maximum never leaves the host).

### Flying drones

`AHeldenDrone` derives from `AActor`, not `AHeldenCharacter`, so an intake
watching `HeldenCharacter` never sees one — drones need their own
`NotifyOnNewObject` and sweep. They also have no stats component and no hit
points at all: just `EHedldenDroneHealth {Default, Wounded, Dead}`, whose state
follows the health of the character flying them (`GetDroneHost`,
`OnHomeHealthChanged_Auth`, `WoundedThreshold`).

So a drone's bar shows its host character's health, which is continuous, exact,
and the number that actually decides whether the drone lives. If the host is
also on screen you will see two bars reading the same values. `DRONES = "state"`
switches to the drone's own three-step reading with the numbers suppressed —
inventing values for a 3-state enum would be worse than showing none. Drones
have no capsule, so their bar height is a fixed offset, and because a drone can
outlive its host the borrowed stats component is revalidated before every read.

## License

MIT — see [LICENSE](LICENSE).
