# Iron Turkey

Replaces [Cold Turkey's](https://getcoldturkey.com/) app-level settings password with macOS admin authorization.

Cold Turkey Blocker is useful, but its local configuration can be
easier to change than many users expect. Iron Turkey adds an OS-enforced guard
that helps Cold Turkey continue enforcing the blocking setup you chose.

Iron Turkey has two modes: **Normal Mode** and **Edit Mode**. 

In Normal Mode, Iron Turkey monitors Cold Turkey,
only keeping tightened policies and increasing statistics.

When launched from Normal Mode, Iron Turkey requests administrator authorization to enter Edit Mode. 
While in Edit Mode, the policy guard is disabled and you can configure Cold Turkey normally.

When launched from Edit Mode, Iron Turkey summarizes policy changes and asks whether
to keep or discard them. Keeping policy changes requires administrator authorization.

Iron Turkey automatically discards unconfirmed policy changes and returns to Normal Mode at **5:00 AM**.

## Install

```bash
sudo ./install.sh
```

This installs:

- `/Applications/Iron Turkey Locker.app`
- `/Library/Application Support/IronTurkeyLocker`
- `/Library/LaunchDaemons/com.ironturkey.locker.guard.plist`
- `/Library/LaunchDaemons/com.ironturkey.locker.restore.plist`

If no baseline exists yet, the installer snapshots the current Cold Turkey local state.

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

The generated app is written to `build/Iron Turkey Locker.app`.
