# Third-Party Notices

## Ghostty / libghostty (GhosttyKit.xcframework)

`GhosttyKit.xcframework` is a macOS (arm64 only) static build of libghostty with the custom-I/O
surface API (`use_custom_io`, `ghostty_surface_feed_data`, `ghostty_surface_set_write_callback`), the
same fork and revision as the iOS framework in `apps/mobile/modules/t3-terminal/Vendor/libghostty`.

- Upstream project: https://github.com/ghostty-org/ghostty
- Source: https://github.com/Yash-Singh1/ghostty (`t3code/custom-io-ordered-feed`)
- Revision: `cf8edc23f3a6a87a96e41a90013e89e987d34980` (also in `VERSION`)
- Based on: https://github.com/wiedymi/ghostty/tree/vvterm/custom-io-padding
- Rebuild: `apps/macos/scripts/build-libghostty-macos.sh`
- License: MIT, reproduced below

Keep this notice, `VERSION` and the iOS notice in sync when the revision changes.

MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
