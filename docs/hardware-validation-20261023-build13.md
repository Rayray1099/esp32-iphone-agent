# Physical iPhone agent validation - build 13

Validated on 2026-10-23 with app version 1.1 (13), commit
`a414095f1411d0d0cf6c1e08ba4af8d03a117a74`, an ESP32-S3 with ST7789 display,
and an iPhone running iOS 27.0.

## Result

The actual agent completed both a Calculator check and the free daily Shopee
Coins check-in. The control path was iPhone AirPlay -> ESP32 -> local Wi-Fi
video -> app CPU H.264 decoder -> configured AI model -> ESP32 Bluetooth HID.
Cellular data was visibly off in Control Center. iCTRL was used for setup,
installation and independent observation; it did not perform either task
during the successful agent runs.

| Check | Evidence and outcome |
| --- | --- |
| Calculator | Run `20261023-153426` entered `12 + 34`; the real Calculator screen displayed `46`. The agent finished successfully at 15:36:09 Taipei and released input. |
| Shopee daily check-in | Run `20261023-155527` finished at 15:57:59 Taipei. The real screen displayed `恭喜！你獲得 3.00 蝦幣！` and a balance of `3.31`. The agent stopped and released input. No purchase or coin spending was requested or observed. |
| App update UI | Settings -> App 更新 displayed installed version `1.1 (13)`. A live check against the published `ios-latest/update.json` displayed latest version `1.1 (13)` and `已是最新版本。`. |
| Saved board data | Five profiles remained present; saved selection remained `{"profiles":[3]}`. |
| Board final state | `running=false`, `releasing=false`, Bluetooth mouse connected, output CPS 0, no last error. |
| Remote display | Authenticated framebuffer capture returned a valid 320 x 240 BMP; the System page showed a readable stopped state. |

## Build and release

[Actions run 39915159544](https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/39915159544)
passed 99 iPhone simulator unit tests and 3 UI tests, with zero failures. This
includes all three AppUpdateTests and the CABAC long-term-reference pixel
regression. The same job produced the device IPA. No additional Actions run
was started for installation, release publication or physical validation.

The original CI IPA was installed through LCSign over the existing app with
the same bundle identifier and signing identity. It was not repacked locally.
The installed app itself confirmed build 13.

[Published prerelease](https://github.com/Rayray1099/esp32-iphone-agent/releases/tag/ios-latest):

- Package: `ESP32-Agent-build13.ipa`, 5,195,208 bytes.
- SHA-256: `7534ce46ab945e7e9683e098a639d78b7984a75d3a577cfd29a0fea1c4ccef5a`.
- Bundle ID: `com.example.esp32agent`; version 1.1; build 13.
- Manifest and package describe the same original unsigned IPA.

The in-app newer-build download, checksum and LCSign handoff path has unit
coverage. The physical phone exercised a same-build update check. A complete
in-app newer-build download and handoff was not tested, since production
metadata was kept accurate and no newer build was manufactured for the test.

A fresh public download of the released IPA matched the published manifest's
byte count and SHA-256. Publishing and downloading these artifacts did not
start a new build.

## Nyxian experiment on the second iPad

Nyxian 0.11.5 Scriptura Beta (20261020.2.RELEASE) compiled its SwiftUI template
and displayed Hello, world! in a guest window. A custom source ZIP imported
successfully, but its use of `@State` failed because the installed toolchain
could not load `SwiftUIMacros.StateMacro`. An earlier missing Resources
directory was a probe archive error and was corrected before this compiler
failure.

The user directed work back to PULSE. No complete PULSE build, Objective-C++
decoder build, extension package or standalone exported IPA was established
with Nyxian. PULSE's working Xcode sources were not changed for this experiment.

## Limits and observed failures

Later testing reproduced the missing-video failure despite AirPlay remaining
connected. Build 14 and a paired firmware keyframe-recovery fix supersede this
build for startup reliability. See
[build 14 validation](hardware-validation-20261023-build14.md) for the failure
mechanism and subsequent physical tests. The successful build 13 runs above
remain historical observations, not proof the earlier failure was resolved.

The first Shopee run struggled with Spotlight focus, appended search text
and a Safari result before eventually opening Shopee. It was stopped without
a verified claim. An isolated ESP32 Bluetooth keyboard test successfully
selected existing text with `cmd+a` and typed `Shopee` exactly. The successful
retry supplied those app-opening instructions and explicitly distinguished
the app icon from web suggestions. This proves the tested task can work,
but not reliable unattended navigation across arbitrary apps.

One guided retry could not start because the board had no usable video.
Reconnecting iOS Screen Mirroring restored it. Quiet screens can cause
several-second post-action waits; observed waits reached roughly 11 seconds.
The successful runs reported no decoded frame drops.

Timing metrics retain a previous run step counter, so later runs can log
`step 40` repeatedly even though the current run is earlier. This is a
diagnostic counter issue; it is not evidence that all those rounds were the
fortieth action. The UI can also count multiple actions within one model
round, exceeding the displayed maximum round count.

The TFT System firmware string remains hardcoded at 0.3.2 while the firmware
package metadata is 0.3.3. This report does not claim that label was fixed.

Physical CPS benchmarks, eduroam authentication, Tailscale relay fallback,
OTA rollback and Nyxian build compatibility were not revalidated by this
particular phone test. Those remain separate acceptance checks.

Private evidence is stored in the ignored `output/agent-20261023/` folder.
It includes screenshots, full iCTRL replies and UART logs. No raw personal
captures, API credentials, signing material or board token are included here.
