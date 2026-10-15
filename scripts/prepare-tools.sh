#!/bin/zsh
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=15.0
PROJECT_DIR="${0:A:h:h}"
TOOLS_DIR="${1:-$PROJECT_DIR/.build-tools}"
mkdir -p "$TOOLS_DIR"
cd "$TOOLS_DIR"
curl -L --fail --retry 2 https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/2026.10.10.233141/yt-dlp_macos -o yt-dlp
echo 'c8ee97b3f6aa0fb5cbc3f56d772c0d79dc2c5d3d60f3bf0b240d5dd0d461fd25  yt-dlp' | shasum -a 256 -c -
# Official directory build avoids repeatedly unpacking/validating runtime libraries.
curl -L --fail --retry 2 https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/2026.10.10.233141/yt-dlp_macos.zip -o yt-dlp_macos.zip
echo '788c2790c5cb15bc3d11b5935741e9ee639e59899329939c7b6d687e11bed8b8  yt-dlp_macos.zip' | shasum -a 256 -c -
mkdir -p yt-dlp-runtime
unzip -o yt-dlp_macos.zip -d yt-dlp-runtime
chmod +x yt-dlp-runtime/yt-dlp_macos
curl -L --fail --retry 2 https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-apple-darwin.zip -o deno.zip
echo '5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c  deno.zip' | shasum -a 256 -c -
unzip -o deno.zip
chmod +x yt-dlp deno
if [[ -f "$PROJECT_DIR/ThirdParty/sources/ffmpeg-8.0.1.tar.xz" ]]; then
  cp "$PROJECT_DIR/ThirdParty/sources/ffmpeg-8.0.1.tar.xz" .
else
  curl -L --fail --retry 2 https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz -o ffmpeg-8.0.1.tar.xz
fi
echo '05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41  ffmpeg-8.0.1.tar.xz' | shasum -a 256 -c -
tar -xf ffmpeg-8.0.1.tar.xz
cd ffmpeg-8.0.1
./configure --prefix="$TOOLS_DIR/ffmpeg-built" --disable-doc --disable-debug --disable-autodetect --disable-everything --disable-ffplay --enable-ffmpeg --enable-ffprobe --enable-small --enable-securetransport --enable-protocol=file,http,https,tcp,tls,crypto,data --enable-demuxer=mov,matroska,hls,mpegts,aac,mp3,ogg,dash --enable-muxer=mp4,mov,ipod,matroska,webm,adts,mp3,null --enable-bsfs --enable-parser=aac,h264,hevc,vp9,av1,mpegaudio --enable-decoder=aac,h264,hevc,vp9,av1,mp3,opus,vorbis,mpeg4,wrapped_avframe,rawvideo,pcm_s16le --enable-encoder=aac,mpeg4,wrapped_avframe,rawvideo,pcm_s16le --enable-filter=anull,null,color,sine,testsrc,format,aresample,scale --enable-indev=lavfi
make -j4
make install
