# Third-party components

- yt-dlp nightly 2026.10.10.233141, official macOS standalone and directory builds: https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/tag/2026.10.10.233141 . Main source: https://github.com/yt-dlp/yt-dlp . The standalone distribution includes components with additional licenses, including GPLv3+; see yt-dlp-THIRD_PARTY_LICENSES.txt and yt-dlp-LICENSE.txt. VidTuck invokes it as a separate process. Bundled EJS scripts and the directory runtime come with the official distributions. Directory build documentation: https://github.com/yt-dlp/yt-dlp#release-files .
- Deno 2.9.7 aarch64-apple-darwin, official unmodified release: https://github.com/denoland/deno/releases/tag/v2.9.7 . MIT license in deno-LICENSE.md. Corresponding source and dependency lockfile: https://github.com/denoland/deno/tree/v2.9.7 . V8 notices in V8-LICENSE.txt and V8-BSD-LICENSE.txt.
- FFmpeg 8.0.1, locally compiled from unmodified official source: https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz . LGPL v2.1 or later. The corresponding complete source archive is included in sources/ alongside this notice. Exact configuration is in ../scripts/prepare-tools.sh. No GPL or nonfree configure option is enabled. FFmpeg is invoked as a separate executable and can be replaced by rebuilding the application with a tools directory of your choice.

SHA-256:

```text
c8ee97b3f6aa0fb5cbc3f56d772c0d79dc2c5d3d60f3bf0b240d5dd0d461fd25  yt-dlp_macos (nightly)
788c2790c5cb15bc3d11b5935741e9ee639e59899329939c7b6d687e11bed8b8  yt-dlp_macos.zip (nightly directory build)
5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c  deno-aarch64-apple-darwin.zip
05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41  ffmpeg-8.0.1.tar.xz
```
