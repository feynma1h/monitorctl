# monitorctl

A tiny macOS menu bar utility for Apple-silicon Macs that are connected to an
external monitor over USB-C. It does two things that macOS has no built-in
switch for:

1. **Monitor off, Mac still charging.** Puts the monitor into standby (via
   DDC/CI) while the USB-C link stays up, so the monitor keeps powering the
   Mac. The Mac's own screen is untouched.
2. **Monitor on, no charge drawn.** Stops the Mac from drawing power from the
   adapter, so it runs on battery while the monitor keeps displaying.

It also has a brightness slider for the monitor. The menu bar icon appears only
while a monitor is connected.

It is a single Objective-C file with no dependencies.

## Requirements

- Apple-silicon Mac
- An external monitor that accepts DDC/CI commands
- Xcode Command Line Tools (`xcode-select --install`)

Developed and tested on a MacBook Air (M4) running macOS 27 with a BenQ
monitor. Other setups may need changes; see [Limitations](#limitations).

## Install

```sh
make
sudo make install        # installs a root-owned binary to /usr/local/bin
make install-agent       # optional: start the menu bar app at login (no sudo)
```

To run it once without installing the login item:

```sh
build/monitorctl menubar
```

Left-click the menu bar icon for the panel. Right-click (or Control-click) for
Quit.

After rebuilding, run `sudo make install` and then `make restart`.

To remove everything: `make uninstall`.

## Using the panel

- **Slider:** monitor brightness.
- **Sleep Monitor:** puts the monitor in standby. Click again to wake it. The
  monitor stays connected, so it keeps charging the Mac.
- **Run on Battery:** stops drawing power from the adapter. Changing this needs
  administrator rights, so macOS asks for your password the first time (see
  [Skipping the password prompt](#skipping-the-password-prompt)).

The menu bar icon shows the current state: display (normal), moon (monitor
asleep), bolt with a slash (adapter off), warning triangle (last action failed).

## Command line

```
monitorctl menubar                      run the menu bar app
monitorctl [-d N] off | on              monitor standby / wake
monitorctl [-d N] brightness [0-100]    get or set brightness
monitorctl [-d N] vcp get|set ...       raw DDC/CI VCP access
monitorctl status                       show DDC brightness and the adapter key
monitorctl keys [prefix]                list SMC keys (for debugging)
sudo monitorctl adapter off|on          run on battery / draw from the adapter
```

`-d N` selects the Nth external display (default 0). The menu bar app always
controls the first one.

## How it works

- **DDC/CI.** Brightness (VCP `0x10`) and power mode (VCP `0xD6`: `1` on,
  `4` standby) are sent to the monitor over I2C with the private
  `IOAVService` API. Standby, unlike setting brightness to 0, turns the panel
  fully dark while keeping the USB-C link up.
- **Adapter control.** The SMC key `CHIE` (`0x08` = disable the adapter,
  `0x00` = enable) is written through the `AppleSMC` user client. This
  requires root. The change takes 5 to 10 seconds to show up and resets on
  reboot. On older macOS versions the `CH0B`/`CH0C`/`CHTE` keys did this job;
  they no longer exist on macOS 27, so this tool only uses `CHIE`.
- **Safety.** If the adapter is off and the battery falls to 15%, the app turns
  the adapter back on.
- **Visibility.** The app keeps running in the background and shows the icon
  only while an external display is present. It stays visible while the adapter
  is off or the monitor is in standby, so you can always undo those states.

## Skipping the password prompt

By default, toggling the adapter shows the macOS administrator prompt. To avoid
it, allow your user to run exactly this command without a password. Edit with
`sudo visudo -f /etc/sudoers.d/monitorctl` and add (replace `youruser`):

```
youruser ALL=(root) NOPASSWD: /usr/local/bin/monitorctl adapter *
```

This is why `make install` gives the binary to root: if a normal user could
overwrite that file, the rule would be a privilege escalation. Only add the rule
if the binary stays root-owned.

## Limitations

- Uses **private Apple APIs** (`IOAVService`) and an **undocumented SMC key**.
  A macOS update can break either without notice.
- The adapter setting is Mac-wide: it stops charging from any adapter, not only
  the monitor.
- Some monitors ignore the DDC standby command, and some docks and adapters do
  not pass DDC through. The panel then reports that the monitor did not
  respond.
- Only the first external display is controlled from the menu bar.
- Not tested on Intel Macs, which use a different DDC path.

## License

MIT. See [LICENSE](LICENSE).
