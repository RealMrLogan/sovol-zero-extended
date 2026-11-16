# Feature plan: filament motion sensor (clog and tangle detection)

Status: planned, nothing built. Researched 2026-11-15.

## Why
The Zero only has a runout switch (`[filament_switch_sensor filament_sensor]`, mainboard PB2). It tells
filament present from absent. A clog, a tangled spool or a grinding extruder leaves filament in the switch,
so none of them are caught and the print carries on in the air.

A motion sensor runs the filament over an encoder wheel. When the extruder has pushed `detection_length`
mm and the wheel hasn't moved, Klipper's `[filament_motion_sensor]` runs its runout action. That covers
clogs, tangles and grinding. A sensorless version (TMC2209 StallGuard on the extruder) was considered and
rejected for now: StallGuard needs StealthChop on a 2209, and it's unreliable at extruder speeds.

## Hardware
- **Sensor:** BIGTREETECH Smart Filament Sensor (SFS) V2.0. One unit with both a runout switch (replaces the
  stock one) and a motion encoder. Minimum detection length about 2.88 mm.
- **Mount:** [Sovol Zero BTT SFS V2 Mount](https://www.printables.com/model/1329519-sovol-zero-btt-sfs-v2-mount)
  attaches at one of the case screw points. Feed the filament through an inlet into the enclosure and a tube
  to the sensor. A shorter, straighter path from sensor to extruder means less slack and more accurate detection.
- **Wiring** (mainboard, Sovol3d/SOVOL-ZERO `Motherboard/Mcu_Pin_definition.pdf`). Three identical
  `3V3 GND <pin>` sockets sit together:

  | Socket | Used by today | Plan |
  |---|---|---|
  | `3V3 GND PB2` | stock runout switch | SFS switch: blue (signal) + red (VCC) |
  | `3V3 GND PE7` | nothing (checked in the printer config) | SFS motion: green (signal) + black (GND) |
  | `3V3 GND PE8` | nothing | spare |

  This is the split a Zero owner uses on the Sovol forum. The SFS has one 4-wire lead, so it has to be
  repinned across two 3-pin plugs.

## Klipper config
```ini
[filament_switch_sensor filament_sensor]     # unchanged name: Sovol's macros and stock screen read it
switch_pin: PB2
pause_on_runout: False
runout_gcode:
    M117 Out of Filament
    CONTINUE_PRINT_D D={200}                 # re-measure D for the SFS position (below)

[filament_motion_sensor encoder_sensor]
switch_pin: PE7
detection_length: 6
extruder: extruder
pause_on_runout: True
runout_gcode:
    M117 Filament not moving
```
- **`detection_length`:** start at 6 mm. On the forum, 4.99 tripped on PETG fine verticals and 5.99 has
  been clean, TPU included. Larger values miss more and react later.
- The motion sensor only checks while a print is running (idle_timeout state "Printing"). Loading,
  unloading and M600 don't trip it.
- **TPU / soft filament:** `SET_FILAMENT_SENSOR SENSOR=encoder_sensor ENABLE=0` in that filament's start
  G-code in the slicer. `detection_length` can't be changed at runtime.
- **Runout switch distance:** Sovol's switch keeps printing for `D=200` mm after runout before M600
  (`CONTINUE_PRINT_D` / `VERIFY_PRINT_D` in `Macro.cfg`), to use up the filament between switch and
  extruder. Set D from the new sensor-to-nozzle path length, minus a margin.
- A clog or tangle pauses straight away (`pause_on_runout: True`). Continuing doesn't help.

## How it fits this firmware
- **No dependency on the upstream updates.** `filament_motion_sensor` is unchanged between our Klipper
  pin and master, so this can go in before or after UPSTREAMS.md step 5 and survive it.
- **Config page toggle** (`release/zero-config/settings.py`): a "Filament motion sensor: off / on" setting,
  following the existing orientation setting.
  - On: write the motion-sensor section to a file the release owns (e.g.
    `~/printer_data/config/zero-extended/filament-motion.cfg`), make sure `printer.cfg` includes it, and
    `FIRMWARE_RESTART`. Off: empty the file and restart.
  - Refuse while printing, as install.sh does.
  - Optional second setting: detection length (5 / 6 / 8 mm), since a config value can't be set at runtime.
  - Defaults to off: with nothing wired to PE7 the pin floats and the sensor would pause prints at random.
- Leave `printer.cfg` otherwise alone. The release already avoids rewriting user config. Only the
  include line is added, the same way install.sh edits `get_ip.cfg`.
- Messages go to `M117`, so they show on the stock screen, Mainsail and KlipperScreen.

## Test plan
1. Wire and mount. `QUERY_FILAMENT_SENSOR SENSOR=encoder_sensor` and the switch both change state by hand.
2. Print a test part. Pinch the filament above the sensor to stop it: the print pauses within about
   `detection_length` mm. Resume continues cleanly.
3. Pull the filament out: the switch path runs Sovol's `CONTINUE_PRINT_D` then M600 with the new D.
4. Print something with many fine verticals and heavy retraction (the false-trigger case) in PLA and PETG.
5. TPU with the sensor disabled from the slicer start G-code.
6. Power-loss resume and the stock screen's filament load/unload still work.

## Open questions
- **3.3 V supply:** PE7's socket gives 3.3 V. The forum setup works, but BTT's spec sheet wasn't checked.
- **Connector type** on the mainboard sockets (JST-XH or PH), needed for crimping.
- Where the stock runout switch physically sits, and whether the SFS replaces it in the same place or
  moves the filament path.
- Whether `^` (pull-up) is needed on PE7 with the SFS.

## Sources
- [BTT SFS v2.0 – Sovol Zero thread, Sovol forum](https://forum.sovol3d.com/t/btt-sfs-v2-0/9130)
- [Sovol Zero BTT SFS V2 Mount (Printables)](https://www.printables.com/model/1329519-sovol-zero-btt-sfs-v2-mount)
- [BTT SFS V2.0 product page](https://us.biqu.equipment/products/btt-sfs-v2-0-smart-filament-sensor)
- [Voron docs: Setup a BTT Smart Filament Sensor](https://docs.vorondesign.com/community/howto/samwiseg0/btt_smart_filament_sensor.html)
- [Klipper forum: BTT SFS motion sensor not stopping print](https://klipper.discourse.group/t/btt-sfs-motion-sensor-v2-0-not-stopping-print/18889)
- Mainboard pinout: Sovol3d/SOVOL-ZERO `Motherboard/Mcu_Pin_definition.pdf`
