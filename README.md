# FaceKey

A menu-bar app that unlocks a Mac when its camera recognises your face, with a Face ID-style animation at the notch.

macOS gives apps no way to approve a login, so FaceKey does what every tool of this kind does: it keeps your login
password encrypted and types it on the lock screen after a match.

FaceKey is built on [Glance](https://github.com/jonnyoo/glance) by Jonathan Zhou: the recognition engine, liveness
checks, lock-screen typing and notch animation are Glance's. FaceKey adds its own settings window, enrolment and
recognition test, builds without Xcode, and changes a few things that did not work well on the Mac it was made on.

## It is a convenience, not a security upgrade

A laptop camera sees a flat image; there is no depth sensor.

- The liveness checks reject a printed photo or a phone screen with reasonable confidence, not a video of you.
- Anyone the app accepts gets your password typed for them.
- The Touch ID gate in front of the stored password is enforced by the app itself, not by the keychain (see below).

Touch ID remains the safer way in. Only use this if you accept the trade-off.

## Requirements

- macOS 15 or later (developed and tested on macOS 27, Apple silicon)
- The Xcode Command Line Tools. Full Xcode is not needed.

## Build

```bash
./build.sh
```

The app lands in `build/FaceKey.app`. Copy it to `/Applications` to use "open at login".

Check the parts that need no camera, Touch ID or lock screen:

```bash
./build/FaceKey.app/Contents/MacOS/FaceKey --self-test
```

### Permissions reset on every rebuild

Without a signing certificate the build is ad-hoc signed, and macOS ties Camera, Accessibility and keychain access to
that exact build. After each rebuild all three have to be granted again.

To avoid that, create a self-signed code-signing certificate named exactly `FaceKey Local Signing` in Keychain Access
(Certificate Assistant › Create a Certificate › Identity Type "Self-Signed Root", Certificate Type "Code Signing").
`build.sh` uses it when it exists.

## Set up

1. Open FaceKey. The settings window shows a checklist.
2. **Authenticate** with Touch ID. This creates the encryption key.
3. Grant **Accessibility** (to type on the lock screen) and **Camera**.
4. Type your Mac login password and press **Save**. FaceKey cannot verify it; a wrong one fails at the first unlock.
5. **Enroll a face**: five poses, two captures each. Enrol from where you normally sit, in your usual light.
6. Run **Test recognition** (nothing is typed) and **Test typing**.
7. Switch on **Unlock this Mac with my face**.

A scan starts when the Mac wakes: lid opened, key pressed after display sleep, or screen saver dismissed. With the
animation on, pointing at the notch on the lock screen starts another scan.

## Settings worth knowing

| Setting | What it does |
|---|---|
| Match strictness | Similarity a face must reach. Scores on the lock screen run lower than in the test, because the light is usually worse. |
| Detection distance | How small a face may be in the frame and still count. |
| Liveness mode | Light only rejects obvious screens and devices. Heavy (default) also needs a blink or a small head movement. |
| Scan for up to | How long a scan looks for a face. A scan that already matches gets up to 7 more seconds for the liveness proof. |
| Lock-screen animation | Full panel, minimal lock glyph, or off. |

## Limits

- After a restart you log in with your password, then confirm FaceKey's Touch ID prompt once.
- Lid closed with an external display: no camera unless another one is selected.
- If the typed password leaves the Mac locked twice in a row, face unlock switches itself off.
- The lock-screen animation uses a private, undocumented macOS interface. A macOS update can break it; unlocking
  itself does not depend on it.

## Where things are stored

Everything stays on the Mac, in `~/Library/Application Support/FaceKey/`:

- `password.enc` and `face-identities.enc`: AES-GCM encrypted under a 256-bit key held in the login keychain.
  Face data is stored as numeric embeddings; camera frames are never written to disk.
- `activity.log`: timestamps, counts and similarity scores of scans. No images, embeddings or passwords.

## What comes from Glance, and what was changed

- `Sources/FaceKey/Glance/` — Glance's files. Most are unchanged apart from identifier renames; a file that was
  changed says so in a "Changed from Glance" comment at the place of the change.
- `Sources/FaceKey/Adapted/` — Glance files reworked for FaceKey; each header lists what changed.
- `Sources/FaceKey/App/` — written for FaceKey.

The changes that affect behaviour:

- **Touch ID gate.** Glance stores its key in a keychain item that the keychain itself gates with Touch ID. That
  needs a build signed with an Apple developer identity. FaceKey asks for Touch ID itself before reading the key.
- **Scan resolution.** Frames are scanned at up to 1600 pixels instead of 640, so a face at a normal sitting
  distance keeps enough detail to match.
- **Device check.** The "device detected" liveness cue fires only when the face sits almost entirely inside a
  detected rectangle, for six frames. Glance's version rejected a real face whenever a door or picture was behind it.
- **Blink check.** Any close-and-reopen in the window counts, not only the lowest reading, and a dip must be deep
  and in both eyes. Thresholds can be tuned without a rebuild:
  `defaults write local.facekey blinkDipLevel 0.5` (also `blinkPerEyeLevel`, `blinkOpenLevel`).
- **Rejected-password guard**, the activity log, and the recognition test are additions.

## Licences

- FaceKey's own code (`Sources/FaceKey/App`, the build script, and the changes made to Glance's files) is MIT
  licensed; see `LICENSE`.
- Glance is MIT licensed, © 2026 Jonathan Zhou; see `LICENSE-Glance.txt`. That covers the code under
  `Sources/FaceKey/Glance` and `Sources/FaceKey/Adapted`, and the animation files in `Resources`. Keep both
  notices when you reuse this project.
- The lock-screen window code is adapted by Glance from [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) (MIT).
- `Resources/ArcFace.mlpackage` is a Core ML conversion of the `w600k_mbf` face model from
  [InsightFace](https://github.com/deepinsight/insightface), as shipped by Glance. InsightFace publishes its
  pretrained models for non-commercial research use only, so do not use this model commercially.
