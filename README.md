# Dissolve — Ephemeral Writing App

<img src="Dissolve.gif" width="50%" alt="Dissolve">

A meditative writing surface for macOS. Type, and your words crumble into a
GPU-simulated granular material — falling, piling, settling into structural
dunes. There is no save. There is no archive. The page is a sandbox for
transient thinking.

## Settings

Open the Settings window (⌘,) for:

- **Font** — picker, live-rendered in each face, populated from system
  font families.
- **Size** — 14–60pt.
- **Decay** — how long a letter holds before crumbling, 3 s to 2 min.
- **Surface** — background and ink color pickers.

## Build

The Xcode project is generated from `project.yml` via
[XcodeGen](https://github.com/yonsm/XcodeGen):

```bash
brew install xcodegen
cd Dissolve_git
xcodegen generate
open Dissolve.xcodeproj
```

Then build/run with ⌘R. The `Dissolve.xcodeproj` directory is regenerated
from `project.yml` and is intentionally not checked in.

## Tech

- Swift, SwiftUI, AppKit, Metal, simd.
- Custom GPU PBD solver (4 substeps, Jacobi position correction with
  Coulomb friction, spatial-hash grid).
- macOS 14+, Apple silicon recommended.

## License

Personal project. Use at your own discretion.
