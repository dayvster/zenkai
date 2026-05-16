const qt = @import("libqt6zig");
const de = @import("desktopapp");

const QWidget = qt.QWidget;
const QLabel = qt.QLabel;
const QHBoxLayout = qt.QHBoxLayout;

pub const AppRow = struct {
    widget: QWidget,
    name_label: QLabel,
    name: []const u8,

    pub fn init(desktop_app: de.DesktopApp, parent: ?*QWidget) AppRow {
        const widget = if (parent) |p| QWidget.New(p.*) else QWidget.New2();
        const layout = QHBoxLayout.New(widget);

        const name_label = QLabel.New3(desktop_app.name);

        layout.AddWidget(name_label);
        layout.AddStretch();

        return .{
            .widget = widget,
            .name_label = name_label,
            .name = desktop_app.name,
        };
    }
};
