#!/bin/zsh
# FFmpeg réduit (LGPL, statique) pour les formats vidéo que macOS ne lit pas : WebM, AVI, WMV/ASF, FLV, OGV, RealMedia, MXF…
# Seulement ce qu'il faut pour lire une image : démultiplexeurs + décodeurs vidéo + conversion (swscale). Aucun GPL, aucun réseau, aucun audio.
# Sortie : ~/Library/Caches/qLOOKS-ffmpeg/out/{include,lib}. Relancé seulement si la sortie manque ou si ce script change.
set -euo pipefail
VER=8.0
BASE="$HOME/Library/Caches/qLOOKS-ffmpeg"
OUT="$BASE/out"
STAMP="$OUT/.built-$(shasum -a 256 "$0" | cut -c1-12)-$VER"
[ -f "$STAMP" ] && exit 0
mkdir -p "$BASE"; cd "$BASE"
[ -f ffmpeg-$VER.tar.xz ] || curl -fsSLo ffmpeg-$VER.tar.xz https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz
rm -rf ffmpeg-$VER build "$OUT"; tar xf ffmpeg-$VER.tar.xz; mkdir build; cd build

DEMUX=matroska,avi,flv,asf,ogg,rm,mxf,gxf,mpegps,mpegts,mov,ivf,nut,yuv4mpegpipe
DEC=vp8,vp9,theora,wmv1,wmv2,wmv3,vc1,msmpeg4v1,msmpeg4v2,msmpeg4v3,mpeg4,flv,vp6,vp6f,vp5,cinepak,indeo2,indeo3,indeo4,indeo5,rv10,rv20,rv30,rv40,mpeg1video,mpeg2video,mjpeg,h263,h264,hevc,svq1,svq3,msvideo1,msrle,rawvideo,huffyuv,ffvhuff,utvideo,dvvideo,prores,dnxhd,png,tscc,cscd,zmbv,amv,qtrle,8bps,smc,rpza,cljr,bmp,gif
PARSE=vp8,vp9,mpeg4video,h264,hevc,h263,mpegvideo,vc1,mjpeg,dvdsub
../ffmpeg-$VER/configure --prefix="$OUT" --arch=arm64 --target-os=darwin --cc=clang \
  --enable-static --disable-shared --enable-pic --extra-cflags="-mmacosx-version-min=15.0" --extra-ldflags="-mmacosx-version-min=15.0" \
  --disable-everything --disable-programs --disable-doc --disable-network --disable-autodetect --disable-debug \
  --disable-avdevice --disable-avfilter --disable-swresample --disable-iconv --disable-xlib \
  --enable-avformat --enable-avcodec --enable-swscale --enable-avutil \
  --enable-protocol=file --enable-demuxer=$DEMUX --enable-decoder=$DEC --enable-parser=$PARSE
make -j"$(sysctl -n hw.ncpu)"
make install
touch "$STAMP"
