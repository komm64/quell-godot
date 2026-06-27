# Quell Godot

Godot binding and demo project for Quell.

This repository contains the public Godot addon wrapper:

- `addons/quell` contains public addon metadata.
- `QuellRuntime` is provided by the synced native GDExtension.
- `scripts/` and `scenes/` contain the demo UI and risk graph.
- The analysis and mitigation implementation is provided separately during
  local development.

The core implementation is intentionally not committed to this repository.

## Install Private Core Locally

From this repository:

```powershell
.\tools\sync_private_core.ps1 ..\quell-core
```

That command copies the local core addons into `addons/quell_core` and
`addons/quell_core_native`. Both directories are ignored by Git.

## Run Demo

```powershell
godot --path .
```

Without `addons/quell_core`, the demo opens with a missing-core notice. With the
private core installed, it runs the GPU `RenderingDevice` demo:

- full-size display output
- reduced Raw and After analysis textures
- Raw risk from the generated source texture
- measured After risk from re-analyzing the corrected texture
- configurable viewing distance and After target
- selectable correction mode:
  - Current frame only: adjusts the displayed frame without sampling the
    previous output frame.
  - Temporal blend: mixes against the previous corrected frame to limit
    frame-to-frame luminance changes.
- HUD graph for Raw, After, and mitigation strength
- `QuellCompositorEffect`, an optional 3D compositor pass that analyzes the
  actual scene color buffer and applies mitigation before display.

## Addon Use

Copy the developer-beta package contents into a Godot project and enable
**Project > Project Settings > Plugins > Quell**. The public node-facing API is
the native `QuellRuntime` class. The analyzer, feedback controller, solver, GPU
metric reducer, mitigation compute shaders, and required developer-beta
logo/URL/Risk overlay are implementation details supplied by the native core
addon.

## License

TBD for the public wrapper.
