# Artwork

`banner.jpg` is the ITGMania Content Browser artwork. The installer renders it
in the terminal (24-bit colour half-blocks) on platforms that can display it,
and the packaging scripts use it for the Windows wizard image and the macOS
disk-image background.

Replacing `banner.jpg` is all it takes to rebrand: the file is embedded into
the binary at build time. If it is absent the installer simply skips the
banner, so the build never depends on it.
