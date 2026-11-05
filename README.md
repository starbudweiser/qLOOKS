# aLPHALOOK

Quick Look previews and thumbnails for `.mov` videos with an alpha channel (ProRes 4444, PNG, Animation), shown on a checkerboard.

## About

aLPHALOOK is a macOS app that hosts two Quick Look extensions (preview and thumbnails). PNG and Animation codecs, which macOS no longer decodes, are read by a built-in decoder; the checkerboard, dark or light background and looped playback are available in the preview bar.
Authors: Starbudweiser & Claude Code (Anthropic). MIT License. Provided as is, without warranty. Not affiliated with Apple or Video Copilot.
See **About aLPHALOOK** in the app menu.

## Build

```
./build_app.sh      # builds in ~/Library/Caches/aLPHALOOK-build, signs, installs in ~/Applications/Applications Personnelles, registers the extensions
```
