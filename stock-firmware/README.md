# Stock board firmware

| File | What | SHA-256 |
|---|---|---|
| `stock-toolhead.bin` | Toolhead (STM32F103) Klipper as shipped, flash 0x08002000 | `60f8fa71eddf0886f69abd998f0291a2fdf27ff056c5695063e61126e91a3b85` |
| `stock-mainboard.bin` | Mainboard (STM32H750) Klipper as shipped: `14d7b18-dirty-20250210_015142-SPI-XI`, flash 0x08020000 | `287ea78b4989684bfe9c3bf917d7afdfbcb847fdd111631b47673fd71619307d` |
| `stock-toolhead-katapult.bin` | Toolhead Katapult bootloader `743f4cf-dirty`, flash 0x08000000 (reference only) | `7542738a3ffbb0d6df14ec21e9ff49cf5a8ec633fce20e2182a95786fda5a9a6` |
| `stock-mainboard-katapult.bin` | Mainboard Katapult bootloader `32c53b2-dirty`, flash 0x08000000 (reference only, never flash this through Katapult) | `13c8faef9ee670da9d3c076651b5cc6c094b16c92ab6565bddb2329660d610a9` |

Read back from the running board on 2026-11-14 with Klipper's `debug_read` (read-only), trailing erased
flash (0xFF) trimmed. Sovol never published a mainboard image, and no Sovol source state we have rebuilds it
exactly (the build was from uncommitted edits), so this dump is the only exact copy.

`stock-toolhead.bin` is Sovol's shipped toolhead image (same file as
`sovol-host/home/sovol/printer_data/build/extruder_mcu_klipper.bin` at the `sovol-stock-reference` tag); `patches/` rebuild it byte-identical.
`VERSIONS` lists the version string each image reports.

Restore: `tools/flash-mcu.sh mainboard stock-firmware/stock-mainboard.bin`
