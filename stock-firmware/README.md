# Stock board firmware

| File | What | SHA-256 |
|---|---|---|
| `stock-mainboard-app.bin` | Mainboard (STM32H750) Klipper as shipped: `14d7b18-dirty-20250210_015142-SPI-XI`, flash 0x08020000 | `287ea78b4989684bfe9c3bf917d7afdfbcb847fdd111631b47673fd71619307d` |
| `stock-mainboard-katapult.bin` | Mainboard Katapult bootloader `32c53b2-dirty`, flash 0x08000000 (reference only, never flash this through Katapult) | `13c8faef9ee670da9d3c076651b5cc6c094b16c92ab6565bddb2329660d610a9` |

Read back from the running board on 2026-11-14 with Klipper's `debug_read` (read-only), trailing erased
flash (0xFF) trimmed. Sovol never published a mainboard image, and no Sovol source state we have rebuilds it
exactly (the build was from uncommitted edits), so this dump is the only exact copy.

The stock toolhead image is `sovol-host/home/sovol/printer_data/build/extruder_mcu_klipper.bin`
(from the 1.4.7 recovery image; `patches/` rebuild it byte-identical).

Restore: `tools/flash-mcu.sh mainboard stock-firmware/stock-mainboard-app.bin`
