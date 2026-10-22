# Ubuntu GNOME and Fedora KDE Plasma

> [!WARNING]
> Experimental, and not yet verified on real hardware. The GNOME and KDE support is built and tested in containers and headless sessions only. Nobody has run it on a physical Ubuntu 26.04 or Fedora 44 desktop with a real microphone, so expect rough edges. The packages are built but not published, so the apt and rpm commands below won't work until they are.

This page covers the Wayland sessions on Ubuntu 26.04 (GNOME) and Fedora 44 (KDE Plasma). X11 sessions aren't supported. On Omarchy and Hyprland, follow the [Linux guide](linux.md) instead.

On these desktops Mouthtype doesn't use a compositor config. It asks the desktop portal for two things, typing access and global shortcuts, and you approve each once.

## Install

Two packages. `mouthtype-linux` is the daemon and command line. `mouthtype-linux-desktop` adds the settings window, tray icon and, on KDE, the floating recording pill. Install both on GNOME and KDE.

**Ubuntu 26.04 (deb):**

```bash
sudo apt install mouthtype-linux mouthtype-linux-desktop
mouthtype-linux-setup
```

This needs the Mouthtype apt source from the [Linux guide](linux.md#install-with-apt), which isn't live yet. Until then, build the packages from `packaging/debian`.

**Fedora 44 (rpm):**

```bash
sudo dnf install ./mouthtype-linux-*.x86_64.rpm ./mouthtype-linux-desktop-*.noarch.rpm
mouthtype-linux-setup
```

There's no COPR repo yet, so build the rpms with `packaging/rpm/build-rpm.sh`. The core package needs `ffmpeg` (Fedora's own or RPM Fusion's), `pw-record` and `notify-send`.

Run `mouthtype-linux-setup` as your normal user, never with sudo. It downloads the speech model (about 465 MiB), runs the doctor check, enables the `mouthtype-linux` user service and adds the settings window to your login autostart so the tray icon is there after you sign in.

## First run and the two prompts

Setup shows two prompts. Both come from your desktop, not from Mouthtype.

1. **Typing permission (Remote Desktop).** During setup the desktop asks whether Mouthtype may control the keyboard. This is how text reaches the app you're in. Approve it and the grant is stored, so you aren't asked again. If you decline, setup carries on and dictation still records. Your text is saved for recovery instead of typed. Ask again with `mouthtype-linux-setup --grant`.
2. **Global Shortcuts.** When the service starts, the desktop shows its shortcut dialog with Mouthtype's four actions. Accept the suggested keys or pick your own.

The desktop reports back what it actually granted, which can differ from the suggestion if a key was taken. Check the shortcut settings in GNOME Settings or KDE System Settings if a key doesn't work.

## Shortcuts

| Action | Suggested keys |
| --- | --- |
| Dictate while held | Ctrl+Alt+M |
| Start or stop dictation (toggle) | Ctrl+Alt+Space |
| Cancel the current take | Ctrl+Alt+Escape |
| Transform the selected text | Ctrl+Alt+R |

Hold Ctrl+Alt+M, speak, and let go. Or tap Ctrl+Alt+Space to start and again to stop. If you let go of a held key and the desktop never reports the release, the take ends anyway.

If the Global Shortcuts portal is missing or you refuse it, GNOME falls back to a single custom keyboard shortcut that runs `mouthtype-linux toggle`. A command shortcut has no key release, so the fallback is toggle only.

## Where the text goes

Delivery starts recovery-only: a take is saved and nothing is typed. To have Mouthtype paste or type into the app you're using, switch the delivery mode in the settings window or set `delivery.mode` to `paste` or `type` in `linux.json`. The same opt-ins as the other Linux setups apply: either list exact `allowed_classes` or set `any_window`, and set `allow_unknown_secure_field` to `true`. See the [setup guide](../../tools/linux-desktop/README.md#config-keys) for the keys.

Two behaviors worth knowing:

- **Password fields.** Mouthtype asks the accessibility bus (AT-SPI) what has focus. If the focused widget is a password field, delivery is refused for typing and pasting alike, and the text goes to recovery. This is best effort. An app that doesn't report focus over AT-SPI shows up as unknown, and the `allow_unknown_secure_field` setting decides what happens then.
- **Clipboard restore.** Paste puts the transcript on the clipboard, sends Ctrl+V, then puts your earlier text clipboard back about 1.5 seconds later. It skips the restore if you copied something else in between, and it never restores an image, a file list or a password manager's copy. Turn it off with `delivery.restore_clipboard`.

## Tray icon and pill

The tray icon shows state and has Start or Stop dictation, Open Mouthtype, Settings and Quit.

- **GNOME** has no tray of its own. The icon needs the AppIndicator extension. Ubuntu ships it and enables it by default, and `mouthtype-linux-desktop` recommends `gnome-shell-extension-appindicator`. That wasn't confirmed against Ubuntu 26.04's archive, so if the icon is missing, check the extension is installed and on. The tray also appears if the extension starts after Mouthtype does.
- **KDE Plasma** shows the icon natively, and also the floating recording pill. The pill needs the layer-shell module (`qml6-module-org-kde-layershell` on Ubuntu, `layer-shell-qt` on Fedora). Without it you get the tray and settings window only. GNOME has no pill.

Open the settings window from the tray, or run `mouthtype-desktop`. `mouthtype-desktop --background` starts tray only, which is what the autostart entry does.

## Check your setup

```bash
mouthtype-linux doctor
```

It's read-only. It reports the detected desktop, which delivery and shortcut backends were chosen, whether the portal answered, the microphone, the speech files, and whether the service is running. Exit status 0 means the required checks passed, 2 means something needs attention. Add `--json` for structured output. Passing doesn't prove the microphone works or that text reaches a particular field.

| Message | What it means and the fix |
| --- | --- |
| `App info not found` | The portal couldn't find a desktop file for Mouthtype. Make sure the package installed `app.mouthtype.Mouthtype.desktop` and that its `Exec` program is on the portal's PATH, then run `update-desktop-database` and sign out and back in. |
| Portal could not be used | `xdg-desktop-portal` or your desktop's backend isn't running. Install `xdg-desktop-portal-gnome` or `xdg-desktop-portal-kde`, and check `systemctl --user status xdg-desktop-portal`. |
| Portal client could not be imported | Install `python3-jeepney`, which has the same name on Ubuntu and Fedora. |
| No tray icon on GNOME | Install and enable the AppIndicator extension, then sign out and back in. Check with `gnome-extensions list --enabled`. |
| Typing never happens, text only lands in recovery | The typing grant is missing or was revoked. Run `mouthtype-linux-setup --grant`, or read the take with `mouthtype-linux list` and `recover ID`. |
| Desktop reported as unknown | You're on an X11 session or an unsupported compositor. Log in to a Wayland session. |
| Service is not answering | Start it with `systemctl --user start mouthtype-linux`, or run `mouthtype-linux serve` in a terminal to see why it stops. |

## Uninstall

Run this before removing the package:

```bash
mouthtype-linux-setup --uninstall
```

It removes the user service, the autostart entry and the GNOME fallback shortcut. Models and recordings stay. Add `--purge` to delete them and the stored typing grant too. To forget the grant on the desktop side, remove Mouthtype in GNOME Settings or KDE System Settings. Then remove the packages:

```bash
sudo apt remove mouthtype-linux-desktop mouthtype-linux   # Ubuntu
sudo dnf remove mouthtype-linux-desktop mouthtype-linux   # Fedora
```
