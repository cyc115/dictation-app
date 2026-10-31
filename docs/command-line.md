# Command line

Every setting can be read and changed from a shell, so a script can switch them for you. A change
is saved where Settings saves it and applies to the running app at once (no restart); it works
whether or not the app is running.

```sh
dictation=/Applications/DictationApp.app/Contents/MacOS/DictationApp

$dictation settings                         # every setting, its value and what it takes
$dictation settings list --json             # the same, as JSON (on/off settings are booleans)
$dictation settings get setup               # just the value: on-device
$dictation settings set setup cloud-flash   # prints: setup = cloud-flash
$dictation settings toggle aiPolishEnabled  # on ⇄ off
```

Exit status: 0 done, 1 unknown setting or value (the error lists what it takes), 2 bad usage.

| Setting | Values |
|---|---|
| `setup` | `on-device`, `cloud-flash`, `cloud-big`, or the `id` of [one of yours](custom-setups.md) |
| `microphoneUID` | `default` (the system's), or a connected mic's name or UID |
| `excludedApps` | bundle IDs, comma-separated (`com.valvesoftware.steam,com.apple.Chess`); `""` for none |
| `openRouterKey` | `-` reads the key from stdin (a key in the arguments shows up in `ps`); `""` removes it. `get` says only `set` or `not set` |
| `launchAtLogin` | `on`, `off` |
| everything else | named by its UserDefaults key: `on`/`off` (also `true`/`false`, `yes`/`no`, `1`/`0`), or one of the values `settings` lists |

New settings show up here on their own: the list is every `@Setting` in `AppSettings`
(`SettingsCommandTests` checks).

## Hammerspoon: cloud on power, on-device on battery or offline

```lua
-- ~/.hammerspoon/dictation.lua; require("dictation") from init.lua.
local dictation = "/Applications/DictationApp.app/Contents/MacOS/DictationApp"
local internet = hs.network.reachability.internet()
local current

local function update()
  local online = (internet:status() & hs.network.reachability.flags.reachable) > 0
  local onPower = hs.battery.powerSource() == "AC Power"
  local setup = (onPower and online) and "cloud-flash" or "on-device"
  if setup == current then return end  -- the battery watcher fires on every percent
  current = setup
  hs.task.new(dictation, nil, { "settings", "set", "setup", setup }):start()
end

DictationPower = hs.battery.watcher.new(update):start()
DictationNetwork = internet:setCallback(update):start()  -- airplane mode, Wi-Fi off
update()
```
