# Repository metadata

The GitHub settings of `n-kasatkin/just-transcribe` that live outside the files.

## Description

```
Super-lightweight dictation for macOS. Press a hotkey, talk, and the text is pasted where your cursor is. A native menu-bar app built on ostt: your own API key or an offline model.
```

## Topics

```
macos, menu-bar-app, dictation, speech-to-text, swift, ostt, whisper, elevenlabs
```

Description and topics in one command, run as the account that owns the repo:

```sh
gh repo edit n-kasatkin/just-transcribe \
  --description "Super-lightweight dictation for macOS. Press a hotkey, talk, and the text is pasted where your cursor is. A native menu-bar app built on ostt: your own API key or an offline model." \
  --add-topic macos --add-topic menu-bar-app --add-topic dictation --add-topic speech-to-text \
  --add-topic swift --add-topic ostt --add-topic whisper --add-topic elevenlabs
```

## Social preview

GitHub has no API for the social preview, so you upload it by hand.

1. Open the repository on github.com → **Settings**.
2. Under **General → Social preview**, click **Edit → Upload an image…**.
3. Pick [`docs/social-preview.png`](social-preview.png) (1280×640). `scripts/make-social-preview.swift` regenerates it.
