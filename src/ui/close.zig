const qt = @import("libqt6zig");

/// Set by the background service, which keeps zenkai running and only hides the launcher.
pub var hide_instead: ?*const fn () void = null;

/// Closes the launcher: quits zenkai, or hides the window when it runs as a background service.
pub fn close() void {
    if (hide_instead) |hide| hide() else qt.QApplication.quit();
}
