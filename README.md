# spz-colorrush

> Color Rush: reach the called colour before the rest drops away.

![version](https://img.shields.io/badge/version-1.0.1-ff6200) ![SPiceZ-Core](https://img.shields.io/badge/SPiceZ--Core-beta-18181b)

## Overview

A huge multicoloured platform in the sky. A colour is called, everyone drives to it, every other colour despawns. The grid shrinks each wave until one car is left. Each round draws a random car category.

## Features

- Waves with shrinking timers
- One jump per wave
- Random car category per round

## Requirements

| Resource | Type |
|---|---|
| `ox_lib` | third-party |
| `spz-minigames` | SPiceZ module |
| `oxmysql` | third-party |
| `spz-core` | SPiceZ module |
| `spz-identity` | SPiceZ module |
| `spz-progression` | SPiceZ module |

## Installation

Included in the [txAdmin recipe](https://github.com/SPiceZ21/spz-txrecipe). Manual install:

1. Download `spz-colorrush` from GitHub (latest release, or the repository) into your `resources` folder.
2. Add to `server.cfg`, after its requirements:

```cfg
ensure spz-colorrush
```

## Configuration

- `config.lua`

See the file for every option.

## Key binds

Rebindable in **Settings → Key Bindings → FiveM**.

| Action | Default |
|---|---|
| Color Rush: car jump (once per wave) | `E` |

---

Part of **SPiceZ-Core** — [documentation](https://github.com/SPiceZ21/Docs) · [all modules](https://github.com/SPiceZ21/Docs/blob/main/modules/README.md)
