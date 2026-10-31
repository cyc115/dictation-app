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

## Hammerspoon: everything on this Mac on battery or offline

On battery, or with no internet (airplane mode, Wi-Fi off), switch to the On-device setup (speech
and polish) and have commands decided on this Mac; on power with internet, put back what was
chosen before. The working version is `~/.hammerspoon/dictation_power.lua` (chezmoi, with
`test_dictation_power.lua`); the core of it:

```lua
local dictation = "/Applications/DictationApp.app/Contents/MacOS/DictationApp"
local saved = "dictation_power.saved"   -- your choice from before, in hs.settings

local function set(name, value)
  hs.execute(dictation .. " settings set " .. name .. " " .. value)
end

local function update()
  local online = (hs.network.reachability.internet():status() & hs.network.reachability.flags.reachable) > 0
  local onBattery = hs.battery.powerSource() == "Battery Power"
  if onBattery or not online then
    if not hs.settings.get(saved) then   -- kept from the first switch, not our own On-device
      hs.settings.set(saved, { setup = hs.execute(dictation .. " settings get setup"):gsub("%s+$", "") })
    end
    set("setup", "on-device")
    -- Only with Decider for Mac in /Applications: without it every command fails.
    if hs.application.pathForBundleID("ai.perplexity.decider"):find("^/Applications/") then
      set("localCommandDecider", "on")
    end
  elseif hs.settings.get(saved) then
    set("setup", hs.settings.get(saved).setup)   -- the real module also puts back localCommandDecider
    hs.settings.set(saved, nil)
  end
end

DictationPower = hs.battery.watcher.new(update):start()   -- fires on every percent: dedupe in real use
DictationNetwork = hs.network.reachability.internet():setCallback(update):start()
update()
```

`hs.application.pathForBundleID` returns `""`, not `nil`, for an app that isn't there, and also
finds stray copies (a `Decider.app` in a download folder), hence the `/Applications` check.
