# Universal Converter

A native macOS app, in the spirit of Tangerine, for converting files by dragging them onto a format.
**Start dragging files anywhere, hold ⇧ Shift, and a floating panel of formats pops up next to the cursor.**
Drop the files on a format and the conversion runs. Everything happens on your Mac; nothing is uploaded.

## Using it
- **Shift-drag:** drag files in Finder (or any app), press Shift, and drop them onto a tile. Hover a category tab (Image, Audio…) while dragging to switch the tiles shown.
- **Main window:** drop files on it, or press ⌘O, then click an action. A search field filters the actions.
- **Dock / Open With / Services:** drop files on the Dock icon, or use Finder ▸ Services ▸ *Convert with Universal Converter*.
- **Favorites:** right-click a tile to pin it. Pinned tiles show first in the panel.
- **Settings:** choose where output goes (next to the original, Downloads, Desktop or a custom folder), whether to reveal results in Finder, and the image quality.

Output never overwrites anything. Results go next to the original (`photo.png`, `photo (rotated).jpg`, `photo 2.png`…).

## What it does (139 actions, ~3,700 format combinations)
| Category | Actions |
| --- | --- |
| Image | PNG, JPEG, HEIC, WebP\*, AVIF, TIFF, GIF, BMP, JPEG 2000, ICO, PSD, TGA, OpenEXR, KTX2, PBM, PDF, ICNS, app icon set, resize, square crop, rotate, flip, grayscale, sepia, invert, auto-enhance, strip metadata, compress, remove background, combine to PDF, animated GIF, info |
| Video | MP4, MOV, M4V, HEVC, ProRes, 4K/1080p/720p/480p, shrink, remove audio, GIF, snapshot, contact sheet, plus WebM, MKV, AVI and MP4 from any container\* |
| Audio (also from video) | M4A, ALAC, WAV, AIFF, FLAC, CAF, AAC, M4R ringtone, AU, mono, voice memo, info, plus MP3, OGG and Opus\* |
| Document | PDF, Word (.docx/.doc), RTF, RTFD, ODT, HTML, Web Archive, plain text, Markdown, speak to audio, word count, combine text. Inputs: docx, doc, rtf, odt, html, md, txt, pdf |
| PDF | pages to PNG/JPEG/HEIC/TIFF, merge (with images), split, compress, flatten, rotate, reverse, remove even pages, first page, info |
| Data | JSON ⇄ YAML ⇄ Plist (XML/binary) ⇄ CSV ⇄ TSV, Markdown and HTML tables, pretty-print/minify JSON, pretty XML, validate |
| Archive | ZIP, tar.gz, tar.bz2, tar.xz, TAR, 7z, gzip, DMG from a folder, extract (zip/tar/gz/bz2/xz/7z/rar…), list contents |
| File actions | OCR text from images and PDFs, read QR codes and barcodes, make a QR code, copy path/name, SHA-256/SHA-1/MD5, Base64 encode/decode, data URI, duplicate, unquarantine, file info, rename (lowercase, kebab, snake, Title, date prefix) |

\* Uses Homebrew `ffmpeg` or `cwebp` if installed (still fully offline). Without them, those tiles are hidden.

Engines: ImageIO, Core Image, AVFoundation, PDFKit, Vision, AppKit text system, and the built-in `afconvert`, `bsdtar`, `ditto`, `hdiutil`, `iconutil` and `say` tools.

## Building
Needs only the Xcode Command Line Tools (macOS 14+):
```
./build.sh
open "build/Universal Converter.app"
```
`build/uconv` is a command-line front end to the same engine:
```
build/uconv list photo.heic            # actions available for a file
build/uconv run image.to.png photo.heic
build/uconv run pdf.merge -o ~/Desktop a.pdf b.pdf
```

Note: on the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships only with full Xcode, so the app uses a small `@Local` wrapper instead (`Sources/UniversalConverter/Local.swift`).
