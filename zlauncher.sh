#!/usr/bin/env bash
exec env QT_STYLE_OVERRIDE=fusion QT_ACCESSIBILITY=0 __GLX_VENDOR_LIBRARY_NAME=none ./zig-out/bin/zlauncher "$@"
