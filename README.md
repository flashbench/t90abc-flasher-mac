# T90ABC Flasher for macOS

**Update the firmware and change the boot logo of ALIENTEK T90A / T90B / T90C soldering irons on a Mac. No Windows needed.**

![T90ABC Flasher](docs/screenshot.png)

The official ALIENTEK updater (`ATK_T90.exe`) runs only on Windows. T90ABC Flasher is a small native Mac app that speaks the same USB protocol, so you can update your iron straight from macOS.

- Updates the firmware from the official ALIENTEK package (ZIP, folder or `.atk` file)
- Changes the boot logo: English, Chinese or your own image
- Shows the version of each firmware in the package (for example 1.1.6)
- Tells you when a new version of the app is available
- Runs on Apple Silicon (M1 and newer) and Intel Macs with macOS 13 Ventura or later
- Interface in English, Russian, Ukrainian, Spanish, Portuguese, German and Chinese

> Unofficial tool, not affiliated with or endorsed by ALIENTEK. Use at your own risk.

## Download

**[Download T90ABC-Flasher-macOS.zip](https://github.com/flashbench/t90abc-flasher-mac/releases/latest/download/T90ABC-Flasher-macOS.zip)** (latest version)

Unzip it and move **T90ABC Flasher** to your *Applications* folder.

### First launch

The app is free and not yet signed with a paid Apple Developer certificate, so macOS blocks it the first time you open it. You only need to allow it once.

**macOS 15 Sequoia and later**

1. Double-click **T90ABC Flasher**. macOS says it could not verify the app. Click **Done**. Do not click *Move to Trash*.
2. Open **System Settings → Privacy & Security** and scroll down to the **Security** section.
3. Next to *“T90ABC Flasher” was blocked*, click **Open Anyway** and confirm with your password or Touch ID.
4. Open the app again and click **Open Anyway** in the dialog.

**macOS 13 Ventura and 14 Sonoma**

Right-click (or Control-click) **T90ABC Flasher**, choose **Open**, then click **Open** in the dialog.

**If there is no Open Anyway button**, run this once in Terminal (adjust the path if the app is not in Applications):

```bash
xattr -dr com.apple.quarantine "/Applications/T90ABC Flasher.app"
```

After this the app opens normally. Each new version needs to be allowed once again.

## How to use

1. Download the official firmware package from the [ALIENTEK download page](https://en.alientek.com/download/p-0-10.html). Look for **T90ABC Smart Soldering Iron**: one package covers the T90A, T90B and T90C.
2. Open T90ABC Flasher and click **Choose…**, or drag the downloaded ZIP into the window.
3. Turn the iron **off**. Press and hold **button B** (the one closest to the screen) and, **while holding it**, connect the iron to your Mac with a USB-C **data** cable. Release the button when the app shows **Ready to update** (green dot).
4. Click **Update firmware**, or **Install logo only** to change just the boot picture.
5. Wait for **Done**, unplug the cable and turn the iron on.

Do not unplug the cable or close the app while an update is running. The app keeps your Mac awake until it finishes.

### Custom boot logo

Select **Custom image** and pick any picture. The best size is **160 × 40 pixels**; other sizes are scaled down to fit on a black background. The preview shows exactly what will appear on the iron.

## Troubleshooting

| Problem | Solution |
|---|---|
| *Soldering iron not connected* | Use a USB-C **data** cable (some cables only charge). Hold button B *before* plugging in. |
| *The iron is not in update mode* | Unplug the cable, hold button B and plug it in again. |
| Auto-rotation behaves incorrectly after an update | Select the *auto-rotation fix* in the firmware list, install it once, then install the latest firmware again. |
| The boot logo is Chinese again after a firmware update | Keep **Also install the logo selected below** checked when updating. |
| macOS says the app is damaged or cannot be opened | Follow [First launch](#first-launch). |

## Security and privacy

- **Open source.** All code is in this repository. There are no third-party libraries.
- **No data collection.** The app contacts only `api.github.com`, to check for a newer version. Nothing about you or your Mac is sent.
- **Firmware comes only from ALIENTEK.** No firmware files are included in this repository or in the app.
- **Built-in safety checks.** The app writes only to an ALIENTEK T90 in update mode, accepts only firmware made for this device type, refuses blocks that could overwrite the iron's bootloader, and rejects damaged or oversized files.

To report a security problem, see [SECURITY.md](SECURITY.md).

## Support

T90ABC Flasher is free. If it helped you, please ⭐ star this repository and share it with other T90 owners.

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

The app and the ZIP appear in `dist/`. Project links and the version number are set at the top of `build.sh`.

**Publishing an update:** raise `VERSION` in `build.sh`, run `./build.sh`, then create a GitHub release tagged `v<VERSION>` with `dist/T90ABC-Flasher-macOS.zip` attached. Installed copies offer the update on their next launch.

## How it works

In update mode the iron is a USB HID device (VID `0x19F5`, PID `0x3245`). Frames look like `[0xAF][cmd][seq][len][data…][checksum]`; replies start with `0xDF`.

| Command | Meaning |
|---|---|
| `0x10` | Read device info |
| `0x11` | Send block header |
| `0x12` | Start transfer |
| `0x13` | Data chunk (32 bytes for firmware, 40 for the logo) |
| `0x14` | End of block |
| `0x15` | Finish and restart |

Firmware data from `.atk` files is sent unchanged; the iron decrypts it itself. The logo block is `"ATKLOGO\0"`, width, height and RGB565 pixels, with every byte inverted. See [`Sources/Protocol.swift`](Sources/Protocol.swift).

## License

[MIT](LICENSE). ALIENTEK and T90 are trademarks of their respective owner.
