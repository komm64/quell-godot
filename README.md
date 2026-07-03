# Quell Godot

Godot binding and demo project for Quell.

Current developer-alpha package version: `0.2.0-developer-alpha`.

This repository contains the public Godot demo wrapper:

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
- fixed developer-alpha runtime preset
- Developer Alpha demo suppresses the debug menu and F1 toggle by default. Use
  `--quell-debug-menu` to enable the debug panel and F1 toggle for local
  development.
- `QuellRuntime.enabled` is the public runtime control. Other analyzer,
  feedback, sampling, solver, and mitigation-policy settings are internal
  runtime preset details. Version `0.2.0-developer-alpha` intentionally
  simplifies the public interface around this enabled-only control.
- HUD graph for Raw, After, and mitigation strength
- `QuellCompositorEffect`, an optional 3D compositor pass that analyzes the
  actual scene color buffer and applies mitigation before display.

## Addon Use

Copy the developer-alpha package contents into a Godot project and open the
project once in the Godot editor so the `.gdextension` is indexed. The public
node-facing API is the native `QuellRuntime` class. Set `enabled` to turn Quell
on or off; the analyzer, feedback controller, solver, sampling cadence, GPU
metric reducer, mitigation compute shaders, and required developer-alpha
logo/URL/Risk overlay are implementation details supplied by the native core
addon.

Developer-alpha packages are experimental developer evaluation builds. They are
not medical devices, diagnostic tools, prevention or treatment tools,
certification services, standards-conformance checkers, or guarantees that
content is safe for photosensitive viewers. Raw Risk and After Risk are internal
Quell signals, not clinical risk estimates.

## License

Quell Godot Developer Alpha uses the Quell Developer Alpha Evaluation License
0.1. See `LICENSE`.

The current alpha package is for Windows x86_64 developer evaluation only. It
does not grant production-use rights.
