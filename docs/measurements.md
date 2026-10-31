# Measurements

The numbers behind "light" in the README, measured by `scripts/measure.sh`.

- Date: 2026-10-31
- Machine: Apple Silicon Mac (arm64), macOS 26.6.2 (25G83)
- Build: commit `010a1bf`, Release configuration, arm64, ostt 0.0.34 helper, Xcode 27.2. Signed with Apple Development under the bundle id `dev.actionhook.justtranscribe.dev` instead of Developer ID; code and resources are the same as a release build.
- DMG: built like `scripts/release.sh` (UDZO, HFS+, the app and an Applications link), unsigned.

## Size

| What | Raw | Rounded |
|---|---|---|
| DMG (`ls -l`) | 10012474 bytes | 10.0 MB |
| Installed app (`du -sk`) | 19976 KB | 19.5 MiB (`du -sh`: 20M) |
| ostt helper, `Contents/Helpers/ostt` (`du -sk`) | 15500 KB | 15.1 MiB, 78% of the app |
| App executable, `Contents/MacOS` (`du -sk`) | 2352 KB | 2.3 MiB |

## Idle

Launched once in the background (`open -g -n`), onboarding marked done, empty temp `XDG_CONFIG_HOME` and `XDG_DATA_HOME` (no engine set up), no window open, measured after 20 s.

| What | Value |
|---|---|
| RSS (`ps -o rss=`, 3 samples 5 s apart) | 72608 KB, 72608 KB, 72608 KB |
| Physical footprint (`footprint -p`) | 14 MB |
| CPU (`top -l 3 -stats pid,cpu,mem`, last sample) | 0.0% |
| Memory (`top`, same sample) | 14M |
| Threads (`ps -M`) | 3 |
| Child processes, ostt included (`ps -o pid,ppid,comm -ax`, by parent PID) | none |

## Commands

```sh
scripts/bootstrap.sh
xcodebuild build -project JustTranscribe.xcodeproj -scheme JustTranscribe -configuration Release \
  -destination "platform=macOS,id=<this Mac's Provisioning UDID>" -derivedDataPath .derivedData \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=3V43DGM2S6 \
  PRODUCT_BUNDLE_IDENTIFIER=dev.actionhook.justtranscribe.dev CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
hdiutil create -volname "just transcribe" -srcfolder <app + Applications link> -fs HFS+ -format UDZO just-transcribe.dmg
ls -l just-transcribe.dmg
du -sh "just transcribe.app"; du -sk "just transcribe.app" "just transcribe.app/Contents/Helpers/ostt"
defaults write dev.actionhook.justtranscribe.dev onboardingCompleted -bool YES
open -g -n --env XDG_CONFIG_HOME=<tmp> --env XDG_DATA_HOME=<tmp> "just transcribe.app"
ps -o rss= -p <pid>            # 3 times, 5 s apart, after 20 s
footprint -p <pid>
top -l 3 -pid <pid> -stats pid,cpu,mem
ps -M -p <pid>
ps -o pid=,ppid=,comm= -ax     # children of <pid>
kill -TERM <pid>
defaults delete dev.actionhook.justtranscribe.dev onboardingCompleted
```
