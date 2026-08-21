# Monterey 12.7 Intel — Build & Run

Your Mac: 2015 Air, 1.6GHz i5, 4GB, no notch. Deployment target lowered to 12.7.

## Fast path (this fork)

1. Install Xcode 14.3.1 (last for Monterey) via https://xcodereleases.com
2. `xcode-select -p` should point to `/Applications/Xcode.app`
3. Build unsigned (preserves Accessibility grant):
   ```
   ./build.sh unsigned
   # app at DerivedData/Build/Products/Debug/FluidVoice\ Debug.app
   ```
4. Launch, grant Mic + Accessibility, pick **Whisper Tiny** (default on 4GB Intel). Apple Speech also works. Parakeet/Nemotron are auto-blocked on Intel with a clear error.

## Why Tiny on 4GB

- Tiny: 44MB, 2GB RAM needed — fastest, no swap
- Base: 81MB, 3GB RAM — will swap on 4GB and feel sluggish

Base is fine on 8GB+.

## Overlay

No-notch hardware auto-falls back to bottom pill overlay (DynamicNotchKit skipped). Top notch still available on notched Macs.

## Known limits

- No Parakeet/Nemotron/Cohere on Intel
- No Fluid Intelligence (3.5GB)
- Streaming preview uses Whisper `timestamps: .segment` — clean segments, not word-level

## Troubleshooting

- **onChange two-param error**: Fixed — all `onChange { _, newValue` → `{ newValue` for 12.7 SDK.
- **SMAppService not found**: Fixed — launch-at-startup gated to 13+ on Monterey.
- **auxiliaryTopLeftArea error**: Fixed — notch check wrapped in `#available(macOS 13)`.
- **Deploy target regression**: `build.sh` fails fast if `15.0` reappears.
- **Slow dictate paste**: Clipboard retries once on 12.7; AX selection retries 80ms.
- **Deploy deps still 15.0**: Run `./scripts/patch-deps-for-monterey.sh` after `swift package resolve`.
