# Frozen Turkey

A small macOS companion utility for [Cold Turkey](https://getcoldturkey.com/).

Cold Turkey is a useful blocking app, but its internal configuration can be
easier to change than many users expect. Frozen Turkey adds a guard
that helps Cold Turkey continue enforcing the blocking setup you chose.

## Usage

Frozen Turkey has two modes: **Normal Mode** and **Edit Mode**. 
Launching Frozen Turkey toggles between the two modes. 
Each mode change requires administrator approval.

In Normal Mode, Frozen Turkey monitors your Cold Turkey configuration,
only keeping changes that are more restrictive.

When entering Edit Mode, Frozen Turkey opens Cold Turkey. 
While in Edit Mode, the guard is disabled so you can adjust your configuration normally.

When returning to Normal Mode, Frozen Turkey asks whether to keep or discard your changes.
Frozen Turkey automatically exits Edit Mode at **5:00 AM**, discarding any unconfirmed changes.


## Install

```bash
sudo ./install.sh
```

This installs:

- `/Applications/Frozen Turkey Locker.app`
- `/Library/Application Support/FrozenTurkeyLocker`
- `/Library/LaunchDaemons/com.frozenturkey.locker.guard.plist`
- `/Library/LaunchDaemons/com.frozenturkey.locker.restore.plist`

If no baseline exists yet, the installer snapshots the current Cold Turkey `data-app.db`.

## Upgrade

```bash
sudo ./install.sh
```

## Uninstall

```bash
sudo ./uninstall.sh
```

## Development

Rebuild the app bundle locally with:

```bash
./build_app.sh
```

The generated app is written to `build/Frozen Turkey Locker.app`.
