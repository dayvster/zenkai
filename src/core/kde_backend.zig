//! Picks the KDE Plasma window backend at build time. kwinctl is a lazy dependency that
//! is only fetched and compiled when `-Dkde` is on (the default for Linux targets), so
//! other builds use a stub that never claims a session.
const build_options = @import("build_options");

pub const enabled = build_options.kde;
pub const impl = if (enabled) @import("window_switcher_kde.zig") else @import("window_switcher_kde_disabled.zig");
