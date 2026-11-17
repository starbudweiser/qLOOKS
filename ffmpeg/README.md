# FFmpeg réduit

qLOOKS embarque une version **réduite de FFmpeg 8.0** (bibliothèques `libavformat`, `libavcodec`, `libswscale`, `libavutil`), liée statiquement, pour afficher les vidéos que macOS ne lit pas (WebM/MKV à codec exotique, AVI, WMV/ASF, FLV, OGV, RealMedia, MXF…).

- Licence : **LGPL v2.1 ou ultérieure**, compilée sans `--enable-gpl` ni `--enable-nonfree` (aucune bibliothèque tierce).
- Contenu limité aux démultiplexeurs et décodeurs vidéo listés dans [`build_ffmpeg.sh`](build_ffmpeg.sh) (aucun encodeur, aucun réseau, aucun audio).
- Code source : <https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz> ; le script télécharge et compile cette version, sans la modifier.
- Utilisation : `Shared/FFSource.swift`. Pour relier qLOOKS à une autre version de FFmpeg, changer `VER` dans le script et recompiler (`./build_app.sh`).

FFmpeg est une marque de Fabrice Bellard ; le projet est © les développeurs de FFmpeg (<https://ffmpeg.org/legal.html>).
