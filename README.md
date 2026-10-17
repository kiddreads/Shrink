# Shrink

An iOS video compressor. Pick a video, then either enter the percentage to cut its size by or the size in MB you want it to end at. Shrink plans the resolution, frame rate and bitrate to hit that target.

- Reads and writes with AVFoundation. HDR sources are tone mapped; rotation and non-square pixels are handled.
- Every output frame is checked against its source frame. Shrink doesn't return a black or much darker frame where the source isn't black. If a pass fails the check it tries a simpler encode path, and if none passes it reports an error instead of handing back a bad file.
- If a target is too small to reach, it says so and shows the smallest size it can do.
- Compression runs on the device. Nothing is uploaded.

Requires iOS 17.0 or later. Build with XcodeGen: `brew install xcodegen && xcodegen generate`, then open `Shrink.xcodeproj`. The GitHub Actions workflow runs the tests and builds an unsigned IPA (artifact `Shrink-ipa`) that you can sign with your own tool.

MIT licensed, see LICENSE.
