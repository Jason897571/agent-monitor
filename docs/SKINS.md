# Skins

The built-in character is a placeholder: a rounded shape drawn in code. A skin swaps it
for any character you have as animated GIFs, APNGs or still PNGs. Sticker packs work
well because they already have transparent backgrounds.

## The settings window

paw print → 设置… (⌘,) → 外观 does all of this without touching files:

- create a skin
- pick one per pose from the images in its folder
- import or drag in a new image
- set per-pose speed
- resize the pet

Every change applies to the pet immediately. The window writes the same `skin.json`
format described below, so a skin you set up there can still be edited by hand.

## Installing one by hand

1. Make a folder under `~/Library/Application Support/AgentMonitor/skins/`. The menu
   item paw print → 角色 → 打开角色文件夹… opens that directory.
2. Put your images in the folder, along with a `skin.json`:

```json
{
  "name": "My cat",
  "poses": {
    "sleeping": "sleeping.gif",
    "working": "typing.gif",
    "resting": "idle.gif",
    "alert": { "file": "wave.gif", "speed": 0.5 }
  }
}
```

3. Choose it from paw print → 角色. The app remembers your choice.

`speed` is a playback multiplier. Set it below 1 for stickers that loop too fast to
read.

## Poses

| Pose | When | Plays |
|---|---|---|
| `sleeping` | no agent is running | looping; paused once faded |
| `waking` | the moment an agent starts | **once**; the pose lasts as long as the animation, clamped to 0.8–3 s |
| `working` | an agent is busy | looping |
| `resting` | an agent is alive and has nothing to do | looping |
| `attentive` | an idle agent has been waiting long enough to deserve a glance | looping |
| `alert` | an agent is blocked on you (permission, question) | looping |
| `digesting` | an agent is compacting its context | looping |
| `swarming` | an agent has two or more subagents running | looping |
| `done` | a turn just finished | looping |
| `troubled` | an error, a spent quota, a crash, or a nearly full context | looping |

You do not need all ten. A pose the skin does not have falls back to its nearest
relative:
- `digesting` and `swarming` fall back to `working`.
- `done` falls back to `attentive`.
- `troubled` falls back to `alert`.
- `alert` falls back to `attentive`.
- `attentive` falls back to `resting`.
- `waking` falls back to `resting`.

Two or three images already make a working character.

## Checking a skin

```sh
agent-monitor --preview-skin <folder-name> preview.png
```

This renders every pose with three frames each, the frame count and loop length, and
which pose it fell back to, if any. A fourth column shows the clickable area.

- **Clickable area.** Only the opaque parts of the image catch clicks. The mask is the
  union of the animation's frames, grown by one cell, so a waving paw does not leave
  click-through holes. A sticker with a solid background can be clicked anywhere in its
  square, so transparent backgrounds work best.
- **Size.** Images are decoded to the pet's size once (132 pt, 264 px on Retina).
  Large source files therefore cost nothing extra at runtime.
- **Memory.** Only the pose on screen is kept decoded.

## Copyright

Most characters people want to use are someone else's intellectual property. Keeping a
skin on your own machine is your business. Skins are user data, which is why they live
in `~/Library/Application Support` and not in the app. **Do not commit third-party art
to this repository, and do not attach it to a release.** A skin you drew yourself, or
one whose licence allows redistribution, is welcome as a separate download.
