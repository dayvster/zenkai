const qt = @import("libqt6zig");
const de = @import("desktopapp");

const QWidget = qt.QWidget;
const QLabel = qt.QLabel;
const QHBoxLayout = qt.QHBoxLayout;

pub const AppRow = struct {
    widget: QWidget,
    icon_label: QLabel,
    name_label: QLabel,
    name: []const u8,

    pub fn init(desktop_app: de.DesktopApp, parent: ?*QWidget) AppRow {
        const widget = if (parent) |p| QWidget.New(p.*) else QWidget.New2();
        const layout = QHBoxLayout.New(widget);

        const icon_label = QLabel.New2();
        icon_label.SetFixedSize2(24, 24);

        const name_label = QLabel.New3(desktop_app.name);

        layout.AddWidget(icon_label);
        layout.AddWidget(name_label);
        layout.AddStretch();

        return .{
            .widget = widget,
            .icon_label = icon_label,
            .name_label = name_label,
            .name = desktop_app.name,
        };
    }
};
