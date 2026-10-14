const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const ModalTeardown = @import("ModalTeardown.zig");
const AppFont = @import("AppFont.zig");
const Dpi = @import("Dpi.zig");
const Tokens = @import("DesignTokens.zig");

extern "user32" fn AdjustWindowRectExForDpi(rect: *c.RECT, style: c.DWORD, menu: c.BOOL, ex_style: c.DWORD, dpi: c.UINT) callconv(.winapi) c.BOOL;
extern "user32" fn GetSystemMetricsForDpi(index: c.INT, dpi: c.UINT) callconv(.winapi) c.INT;

const window_style = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_CLIPCHILDREN;
const window_ex_style = c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT;
const content_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWindowsDialogContent");
var panel_brush: c.HBRUSH = null;
var edit_brush: c.HBRUSH = null;

const Layout = struct {
    width: i32 = 0,
    viewport_height: i32 = 0,
    footer_height: i32 = 0,
    extent: i32 = 0,
    inset: i32 = 0,
    text_width: i32 = 0,
    description_height: i32 = 0,
    label_y: [16]i32 = [_]i32{0} ** 16,
    label_height: [16]i32 = [_]i32{0} ** 16,
    edit_y: [16]i32 = [_]i32{0} ** 16,
    edit_height: i32 = 0,
    button_width: i32 = 0,
    button_height: i32 = 0,

    fn maxOffset(self: Layout) i32 {
        return @max(0, self.extent - self.viewport_height);
    }
};

pub const Result = struct {
    values: [16][]u8,
    count: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.values[0..self.count]) |value| allocator.free(value);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    parent: c.HWND,
    labels: [16][]const u8 = [_][]const u8{""} ** 16,
    values: [16][]u8 = [_][]u8{&.{}} ** 16,
    label_windows: [16]c.HWND = [_]c.HWND{null} ** 16,
    edits: [16]c.HWND = [_]c.HWND{null} ** 16,
    description: []const u8 = "",
    description_window: c.HWND = null,
    viewport: c.HWND = null,
    dpi: u32 = Dpi.base_dpi,
    layout: Layout = .{},
    window_rect: c.RECT = std.mem.zeroes(c.RECT),
    count: usize = 0,
    scroll_offset: i32 = 0,
    accepted: bool = false,
    closed: bool = false,
    failure: ?anyerror = null,
    button_y: i32 = 565,
    /// The control that owns keyboard focus whenever the dialog is active: the first
    /// field on open, then whichever child the user left focused when it deactivated.
    focus: c.HWND = null,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWindowsDialog");
const ok_id = 9800;
const cancel_id = 9808;
var active = false;
var active_state: State = undefined;

pub fn text(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    title: []const u8,
    labels: []const []const u8,
    initial: []const []const u8,
) !?Result {
    return textWithDescription(parent, allocator, title, "", labels, initial);
}

pub fn textWithDescription(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    title: []const u8,
    description: []const u8,
    labels: []const []const u8,
    initial: []const []const u8,
) !?Result {
    if (active) return error.DialogAlreadyOpen;
    if (labels.len == 0 or labels.len > 16 or labels.len != initial.len) return error.InvalidDialogFields;
    var state = State{
        .allocator = allocator,
        .parent = parent,
        .count = labels.len,
        .description = description,
    };
    for (labels, 0..) |label, index| {
        state.labels[index] = label;
        state.values[index] = allocator.dupe(u8, initial[index]) catch |err| {
            freeStateValues(&state);
            return err;
        };
    }

    registerClass() catch |err| {
        freeStateValues(&state);
        return err;
    };
    const wide_title = wideZ(allocator, title) catch |err| {
        freeStateValues(&state);
        return err;
    };
    defer allocator.free(wide_title);
    active_state = state;
    active_state.closed = false;
    active_state.accepted = false;
    active = true;
    const hwnd = createTextDialog(parent, wide_title) orelse {
        const failure = active_state.failure orelse error.DialogCreationFailed;
        freeStateValues(&active_state);
        active = false;
        return failure;
    };
    _ = c.EnableWindow(parent, 0);
    presentDialog(hwnd);
    var message: c.MSG = undefined;
    while (!active_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            active_state.closed = true;
            break;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    ModalTeardown.dismiss(hwnd, parent);
    active = false;
    return finishText(&active_state);
}

fn createTextDialog(parent: c.HWND, wide_title: []const u16) c.HWND {
    active_state.dpi = Dpi.normalize(Win32.dpiForWindow(parent));
    fitWindow(&active_state, null) catch |err| {
        active_state.failure = err;
        return null;
    };
    return createDialogWindow(parent, wide_title);
}

fn createDialogWindow(parent: c.HWND, wide_title: []const u16) c.HWND {
    const rect = active_state.window_rect;
    return c.CreateWindowExW(
        window_ex_style,
        class_name.ptr,
        wide_title.ptr,
        window_style,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    );
}

fn presentDialog(hwnd: c.HWND) void {
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    if (active_state.focus) |target| _ = c.SetFocus(target);
}

fn finishText(state: *State) !?Result {
    if (state.failure) |err| {
        freeStateValues(state);
        return err;
    }
    if (!state.accepted) {
        freeStateValues(state);
        return null;
    }
    const result = Result{ .values = state.values, .count = state.count };
    state.values = [_][]u8{&.{}} ** 16;
    state.count = 0;
    return result;
}

const TextCommand = enum { submit, cancel, close };

fn applyTextCommand(state: *State, command: TextCommand) void {
    if (command == .submit) {
        readValues(state) catch |err| {
            state.failure = err;
            state.accepted = false;
            state.closed = true;
            return;
        };
        state.accepted = true;
    } else {
        state.accepted = false;
    }
    state.closed = true;
}

fn freeStateValues(state: *State) void {
    for (state.values[0..state.count]) |value| state.allocator.free(value);
    state.values = [_][]u8{&.{}} ** 16;
    state.count = 0;
}

fn registerClass() !void {
    if (panel_brush == null) panel_brush = c.CreateSolidBrush(Tokens.dialog_panel);
    if (edit_brush == null) edit_brush = c.CreateSolidBrush(Tokens.dialog_field_background);
    if (panel_brush == null or edit_brush == null) return error.DialogBrushCreationFailed;
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&windowProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    klass.hbrBackground = panel_brush;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
    klass.lpfnWndProc = @ptrCast(&contentProc);
    klass.lpszClassName = content_class.ptr;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            createControls(hwnd, &active_state) catch |err| {
                active_state.failure = err;
                return -1;
            };
            if (active_state.edits[0]) |first| {
                _ = c.SendMessageW(first, c.EM_SETSEL, 0, -1);
                active_state.focus = first;
            }
            return 0;
        },
        c.WM_SIZE => {
            if (active_state.viewport != null) relayout(hwnd) catch |err| {
                failDialog(err);
            };
            return 0;
        },
        c.WM_DPICHANGED => {
            active_state.dpi = Dpi.normalize(@intCast(wparam & 0xffff));
            const suggested = if (lparam == 0) null else Win32.messagePointer(*const c.RECT, lparam);
            fitWindow(&active_state, suggested) catch |err| {
                failDialog(err);
                return 0;
            };
            const rect = active_state.window_rect;
            if (c.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0)
                failDialog(error.DialogLayoutFailed);
            return 0;
        },
        c.WM_CTLCOLORSTATIC, c.WM_CTLCOLOREDIT, c.WM_CTLCOLORBTN => {
            const dc = Win32.opaquePointerFromInt(c.HDC, wparam);
            const is_edit = message == c.WM_CTLCOLOREDIT;
            _ = c.SetBkMode(dc, c.OPAQUE);
            _ = c.SetBkColor(dc, if (is_edit) Tokens.dialog_field_background else Tokens.dialog_panel);
            _ = c.SetTextColor(dc, Tokens.dialog_title_text);
            return @bitCast(@intFromPtr(if (is_edit) edit_brush else panel_brush));
        },
        c.WM_MOUSEWHEEL => return c.SendMessageW(active_state.viewport, message, wparam, lparam),
        // This is a plain window, not a dialog-manager dialog, so nothing hands focus to
        // a control on its own: DefWindowProc's activation leaves it on the frame, where
        // typing goes nowhere. Route it to the remembered control instead.
        c.WM_ACTIVATE => {
            if ((wparam & 0xffff) == c.WA_INACTIVE) {
                const current = c.GetFocus();
                if (current != null and c.IsChild(hwnd, current) != 0) active_state.focus = current;
            } else if (active_state.focus) |target| {
                _ = c.SetFocus(target);
            }
            return 0;
        },
        c.WM_SETFOCUS => {
            if (active_state.focus) |target| _ = c.SetFocus(target);
            return 0;
        },
        // IsDialogMessage routes Enter to the default button reported here and Escape to
        // IDCANCEL; without a reply Enter in a field is silently dropped. A focused
        // button keeps Enter for itself, as in a dialog-manager dialog.
        c.DM_GETDEFID => {
            var default_id: usize = ok_id;
            const focused = c.GetFocus();
            if (focused != null and c.IsChild(hwnd, focused) != 0) {
                const focused_id: usize = @intCast(c.GetDlgCtrlID(focused));
                if (focused_id == cancel_id) default_id = cancel_id;
            }
            return @as(c.LRESULT, @intCast(default_id)) | (@as(c.LRESULT, c.DC_HASDEFID) << 16);
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            const notification: u16 = @truncate(wparam >> 16);
            if (notification == c.EN_SETFOCUS) {
                for (active_state.edits[0..active_state.count], 0..) |edit, index| {
                    if (edit == Win32.messagePointer(c.HWND, lparam)) {
                        revealField(index) catch |err| failDialog(err);
                        break;
                    }
                }
            }
            if (command == ok_id or command == c.IDOK) {
                applyTextCommand(&active_state, .submit);
                return 0;
            }
            if (command == cancel_id or command == c.IDCANCEL) {
                applyTextCommand(&active_state, .cancel);
                return 0;
            }
        },
        c.WM_KEYDOWN => {
            if (wparam == c.VK_RETURN) {
                applyTextCommand(&active_state, .submit);
                return 0;
            }
            if (wparam == c.VK_ESCAPE) {
                applyTextCommand(&active_state, .cancel);
                return 0;
            }
        },
        c.WM_CLOSE => {
            applyTextCommand(&active_state, .close);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn failDialog(err: anyerror) void {
    active_state.failure = err;
    active_state.accepted = false;
    active_state.closed = true;
}

fn textHeight(state: *State, dc: c.HDC, value: []const u8, width: i32) !i32 {
    const wide = try wideZ(state.allocator, value);
    defer state.allocator.free(wide);
    var rect = c.RECT{ .left = 0, .top = 0, .right = width, .bottom = 0 };
    if (c.DrawTextW(dc, wide.ptr, @intCast(wide.len - 1), &rect, c.DT_CALCRECT | c.DT_WORDBREAK | c.DT_NOPREFIX | c.DT_EDITCONTROL) == 0)
        return error.DialogTextMeasurementFailed;
    return rect.bottom;
}

fn measure(state: *State, width: i32, height: i32) !Layout {
    const dpi = state.dpi;
    const dc = c.CreateCompatibleDC(null) orelse return error.DialogTextMeasurementFailed;
    defer _ = c.DeleteDC(dc);
    const font = AppFont.getForDpi(AppFont.control_size, false, dpi) orelse return error.DialogFontCreationFailed;
    const previous = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, previous);
    var layout = Layout{
        .width = width,
        .inset = Dpi.scale(18, dpi),
        .footer_height = Dpi.scale(56, dpi),
        .edit_height = Dpi.scale(28, dpi),
        .button_width = Dpi.scale(80, dpi),
        .button_height = Dpi.scale(28, dpi),
    };
    layout.viewport_height = @max(0, height - layout.footer_height);
    // Reserve the scrollbar before wrapping so overflow cannot change the text width.
    layout.text_width = width - layout.inset * 2 - GetSystemMetricsForDpi(c.SM_CXVSCROLL, dpi);
    if (layout.text_width <= 0 or width < layout.inset * 2 + layout.button_width * 2 + Dpi.scale(10, dpi))
        return error.DialogWorkAreaTooSmall;
    var y = Dpi.scale(12, dpi);
    if (state.description.len != 0) {
        layout.description_height = try textHeight(state, dc, state.description, layout.text_width);
        y += layout.description_height + Dpi.scale(12, dpi);
    }
    for (state.labels[0..state.count], 0..) |label, index| {
        layout.label_y[index] = y;
        layout.label_height[index] = if (label.len == 0) Dpi.scale(18, dpi) else try textHeight(state, dc, label, layout.text_width);
        y += layout.label_height[index] + Dpi.scale(4, dpi);
        layout.edit_y[index] = y;
        y += layout.edit_height + Dpi.scale(12, dpi);
    }
    layout.extent = y;
    return layout;
}

fn fitWindow(state: *State, suggested: ?*const c.RECT) !void {
    var monitor = std.mem.zeroes(c.MONITORINFO);
    monitor.cbSize = @sizeOf(c.MONITORINFO);
    const target_monitor = if (suggested) |rect|
        c.MonitorFromRect(rect, c.MONITOR_DEFAULTTONEAREST)
    else
        c.MonitorFromWindow(state.parent, c.MONITOR_DEFAULTTOPRIMARY);
    if (c.GetMonitorInfoW(target_monitor, &monitor) == 0)
        return error.DialogWorkAreaFailed;
    var frame = std.mem.zeroes(c.RECT);
    if (AdjustWindowRectExForDpi(&frame, window_style, 0, window_ex_style, state.dpi) == 0)
        return error.DialogFrameMeasurementFailed;
    const work = monitor.rcWork;
    const frame_width = frame.right - frame.left;
    const frame_height = frame.bottom - frame.top;
    const width = @min(Dpi.scale(560, state.dpi), work.right - work.left - frame_width);
    const measured = try measure(state, width, 0);
    const height = @min(measured.extent + measured.footer_height, @min(Dpi.scale(620, state.dpi), work.bottom - work.top - frame_height));
    if (height < measured.footer_height + measured.edit_height) return error.DialogWorkAreaTooSmall;
    var owner = work;
    if (suggested == null and state.parent != null and c.GetWindowRect(state.parent, &owner) == 0) return error.DialogOwnerRectFailed;
    const outer_width = width + frame_width;
    const outer_height = height + frame_height;
    const desired_x = if (suggested) |rect| rect.left else owner.left + @divTrunc(owner.right - owner.left - outer_width, 2);
    const desired_y = if (suggested) |rect| rect.top else owner.top + @divTrunc(owner.bottom - owner.top - outer_height, 2);
    const x = std.math.clamp(desired_x, work.left, work.right - outer_width);
    const y = std.math.clamp(desired_y, work.top, work.bottom - outer_height);
    state.window_rect = .{ .left = x, .top = y, .right = x + outer_width, .bottom = y + outer_height };
}

fn control(state: *State, parent: c.HWND, class: [*:0]const u16, label: []const u8, ex_style: c.DWORD, style: c.DWORD, id: usize) !c.HWND {
    const wide = try wideZ(state.allocator, label);
    defer state.allocator.free(wide);
    return c.CreateWindowExW(ex_style, class, wide.ptr, @bitCast(@as(c.DWORD, c.WS_CHILD | c.WS_VISIBLE) | style), 0, 0, 0, 0, parent, Win32.opaquePointerFromInt(c.HMENU, id), c.GetModuleHandleW(null), null) orelse error.DialogControlCreationFailed;
}

fn createControls(hwnd: c.HWND, state: *State) !void {
    state.viewport = try control(state, hwnd, content_class, "", c.WS_EX_CONTROLPARENT, c.WS_CLIPCHILDREN | c.WS_VSCROLL, 0);
    const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    if (state.description.len != 0)
        state.description_window = try control(state, state.viewport, static_class, state.description, 0, c.SS_NOPREFIX | c.SS_EDITCONTROL, 0);
    for (state.labels[0..state.count], 0..) |label, index| {
        state.label_windows[index] = try control(state, state.viewport, static_class, label, 0, c.SS_NOPREFIX | c.SS_EDITCONTROL, 0);
        state.edits[index] = try control(state, state.viewport, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), state.values[index], c.WS_EX_CLIENTEDGE, c.WS_TABSTOP | c.ES_AUTOHSCROLL, 9904 + index * 8);
    }
    _ = try control(state, hwnd, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), "OK", 0, c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, ok_id);
    _ = try control(state, hwnd, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), "Cancel", 0, c.WS_TABSTOP | c.BS_PUSHBUTTON, cancel_id);
    try relayout(hwnd);
}

fn moveControl(state: *State, hwnd: c.HWND, x: i32, y: i32, width: i32, height: i32) !void {
    const font = AppFont.getForDpi(AppFont.control_size, false, state.dpi) orelse return error.DialogFontCreationFailed;
    _ = c.SendMessageW(hwnd, c.WM_SETFONT, @intFromPtr(font), 0);
    if (c.SetWindowPos(hwnd, null, x, y, width, height, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0)
        return error.DialogLayoutFailed;
}

fn relayout(hwnd: c.HWND) !void {
    const state = &active_state;
    var client: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &client) == 0) return error.DialogLayoutFailed;
    if (client.right == 0 or client.bottom == 0) return;
    state.layout = try measure(state, client.right, client.bottom);
    const layout = state.layout;
    if (client.bottom < layout.footer_height + layout.edit_height) return error.DialogWorkAreaTooSmall;
    state.button_y = layout.viewport_height + @divTrunc(layout.footer_height - layout.button_height, 2);
    try moveControl(state, state.viewport, 0, 0, layout.width, layout.viewport_height);
    try moveControl(state, c.GetDlgItem(hwnd, ok_id), layout.width - layout.inset - layout.button_width, state.button_y, layout.button_width, layout.button_height);
    try moveControl(state, c.GetDlgItem(hwnd, cancel_id), layout.width - layout.inset - layout.button_width * 2 - Dpi.scale(10, state.dpi), state.button_y, layout.button_width, layout.button_height);
    try setScrollOffset(state.scroll_offset);
    if (c.RedrawWindow(hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN) == 0)
        return error.DialogRedrawFailed;
}

fn setScrollOffset(offset: i32) !void {
    const state = &active_state;
    const layout = state.layout;
    state.scroll_offset = std.math.clamp(offset, 0, layout.maxOffset());
    var info = std.mem.zeroes(c.SCROLLINFO);
    info.cbSize = @sizeOf(c.SCROLLINFO);
    info.fMask = c.SIF_RANGE | c.SIF_PAGE | c.SIF_POS;
    info.nMax = @max(0, layout.extent - 1);
    info.nPage = @intCast(layout.viewport_height);
    info.nPos = state.scroll_offset;
    _ = c.SetScrollInfo(state.viewport, c.SB_VERT, &info, 1);
    if (state.description_window != null)
        try moveControl(state, state.description_window, layout.inset, Dpi.scale(12, state.dpi) - state.scroll_offset, layout.text_width, layout.description_height);
    for (0..state.count) |index| {
        try moveControl(state, state.label_windows[index], layout.inset, layout.label_y[index] - state.scroll_offset, layout.text_width, layout.label_height[index]);
        try moveControl(state, state.edits[index], layout.inset, layout.edit_y[index] - state.scroll_offset, layout.text_width, layout.edit_height);
    }
    if (c.RedrawWindow(state.viewport, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN) == 0)
        return error.DialogRedrawFailed;
}

fn revealField(index: usize) !void {
    const layout = active_state.layout;
    const top = layout.label_y[index];
    const bottom = layout.edit_y[index] + layout.edit_height;
    var offset = active_state.scroll_offset;
    if (layout.edit_y[index] < offset) offset = layout.edit_y[index];
    if (bottom > offset + layout.viewport_height) offset = bottom - layout.viewport_height;
    // Keep a wrapped label if it fits together with its edit; otherwise prioritize the edit.
    if (top < offset and bottom - top <= layout.viewport_height) offset = top;
    try setScrollOffset(offset);
}

fn contentProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_COMMAND, c.WM_DRAWITEM, c.WM_CTLCOLORSTATIC, c.WM_CTLCOLOREDIT, c.WM_CTLCOLORBTN => return c.SendMessageW(c.GetParent(hwnd), message, wparam, lparam),
        c.WM_VSCROLL => {
            var info = std.mem.zeroes(c.SCROLLINFO);
            info.cbSize = @sizeOf(c.SCROLLINFO);
            info.fMask = c.SIF_TRACKPOS;
            const line = Dpi.scale(28, active_state.dpi);
            const offset = active_state.scroll_offset;
            const target = switch (@as(u16, @truncate(wparam))) {
                c.SB_LINEUP => offset - line,
                c.SB_LINEDOWN => offset + line,
                c.SB_PAGEUP => offset - active_state.layout.viewport_height,
                c.SB_PAGEDOWN => offset + active_state.layout.viewport_height,
                c.SB_TOP => 0,
                c.SB_BOTTOM => active_state.layout.maxOffset(),
                c.SB_THUMBTRACK, c.SB_THUMBPOSITION => blk: {
                    if (c.GetScrollInfo(hwnd, c.SB_VERT, &info) == 0) {
                        failDialog(error.DialogScrollReadFailed);
                        return 0;
                    }
                    break :blk info.nTrackPos;
                },
                else => return 0,
            };
            setScrollOffset(target) catch |err| failDialog(err);
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            setScrollOffset(active_state.scroll_offset - @divTrunc(@as(i32, delta) * Dpi.scale(84, active_state.dpi), c.WHEEL_DELTA)) catch |err| failDialog(err);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn readValues(state: *State) !void {
    var buffer: [4096]u16 = undefined;
    for (0..state.count) |index| {
        if (c.IsWindow(state.edits[index]) == 0) return error.DialogReadFailed;
        if (c.GetWindowTextLengthW(state.edits[index]) >= buffer.len) return error.DialogTextTooLong;
        c.SetLastError(0);
        const length = c.GetWindowTextW(state.edits[index], &buffer, @intCast(buffer.len));
        if (length == 0 and c.GetLastError() != 0) return error.DialogReadFailed;
        const value = try std.unicode.utf16LeToUtf8Alloc(state.allocator, buffer[0..@intCast(length)]);
        state.allocator.free(state.values[index]);
        state.values[index] = value;
    }
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

test "native dialog field contract preserves Unicode and field count" {
    const labels = [_][]const u8{ "URL", "Destination" };
    try std.testing.expectEqual(labels.len, 2);
    try std.testing.expect(std.unicode.utf8ValidateSlice("Проекты\\über"));
}

fn hiddenPrompt(count: usize, description: []const u8) !c.HWND {
    return hiddenPromptForDpi(count, description, Dpi.base_dpi);
}

fn hiddenPromptForDpi(count: usize, description: []const u8, dpi: u32) !c.HWND {
    active_state = State{ .allocator = std.testing.allocator, .parent = null, .count = count, .description = description };
    errdefer freeStateValues(&active_state);
    for (0..count) |index| {
        active_state.labels[index] = "Title";
        active_state.values[index] = try std.testing.allocator.dupe(u8, "fixture");
    }
    active = true;
    try registerClass();
    active_state.dpi = dpi;
    try fitWindow(&active_state, null);
    return createDialogWindow(null, std.unicode.utf8ToUtf16LeStringLiteral("Prompt fixture")) orelse return active_state.failure orelse error.TestWindowCreationFailed;
}

fn rectIn(window: c.HWND, parent: c.HWND) !c.RECT {
    var rect: c.RECT = undefined;
    if (c.GetWindowRect(window, &rect) == 0) return error.TestWindowRectFailed;
    _ = c.MapWindowPoints(null, parent, @ptrCast(&rect), 2);
    return rect;
}

test "sheet framework: no-description prompt footer fits actual client" {
    defer active = false;
    for ([_]usize{ 1, 4 }) |count| {
        const hwnd = try hiddenPrompt(count, "");
        defer {
            _ = c.DestroyWindow(hwnd);
            freeStateValues(&active_state);
        }
        var client: c.RECT = undefined;
        try std.testing.expect(c.GetClientRect(hwnd, &client) != 0);
        for ([_]c.HWND{ c.GetDlgItem(hwnd, ok_id), c.GetDlgItem(hwnd, cancel_id) }) |button| {
            const rect = try rectIn(button, hwnd);
            try std.testing.expect(rect.bottom <= client.bottom);
        }
    }
}

test "sheet framework: description prompt footer fits actual client" {
    defer active = false;
    for ([_]usize{ 1, 4 }) |count| {
        const hwnd = try hiddenPrompt(count, "Only the name changes; the session and edges stay.");
        defer {
            _ = c.DestroyWindow(hwnd);
            freeStateValues(&active_state);
        }
        var client: c.RECT = undefined;
        try std.testing.expect(c.GetClientRect(hwnd, &client) != 0);
        const button = try rectIn(c.GetDlgItem(hwnd, ok_id), hwnd);
        try std.testing.expect(button.bottom <= client.bottom);
        const edit = try rectIn(active_state.edits[count - 1], hwnd);
        try std.testing.expect(edit.bottom <= button.top);
    }
}

test "sheet framework: static labels paint an opaque panel background" {
    defer active = false;
    const hwnd = try hiddenPrompt(1, "Description");
    defer {
        _ = c.DestroyWindow(hwnd);
        freeStateValues(&active_state);
    }
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    const brush = c.SendMessageW(active_state.viewport, c.WM_CTLCOLORSTATIC, @intFromPtr(dc), @bitCast(@intFromPtr(active_state.label_windows[0])));
    try std.testing.expect(brush != 0);
    try std.testing.expectEqual(@as(c.INT, c.OPAQUE), c.GetBkMode(dc));
    var info: c.LOGBRUSH = undefined;
    try std.testing.expect(c.GetObjectW(Win32.opaquePointerFromInt(c.HBRUSH, @bitCast(brush)), @sizeOf(c.LOGBRUSH), &info) != 0);
    try std.testing.expectEqual(@as(c.UINT, c.BS_SOLID), info.lbStyle);
    try std.testing.expectEqual(Tokens.dialog_panel, c.GetBkColor(dc));
    try std.testing.expectEqual(Tokens.dialog_panel, info.lbColor);
}

test "sheet framework: 1 4 16 fields partition actual client at 96 144 192 DPI" {
    defer active = false;
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        for ([_]usize{ 1, 4, 16 }) |count| {
            const hwnd = try hiddenPromptForDpi(count, "Long description " ** 30, dpi);
            defer {
                _ = c.DestroyWindow(hwnd);
                freeStateValues(&active_state);
            }
            try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
            var client: c.RECT = undefined;
            try std.testing.expect(c.GetClientRect(hwnd, &client) != 0);
            const layout = active_state.layout;
            const viewport = try rectIn(active_state.viewport, hwnd);
            try std.testing.expectEqual(@as(i32, 0), viewport.top);
            try std.testing.expectEqual(layout.viewport_height, viewport.bottom);
            try std.testing.expectEqual(client.bottom, layout.viewport_height + layout.footer_height);
            for ([_]c.HWND{ c.GetDlgItem(hwnd, ok_id), c.GetDlgItem(hwnd, cancel_id) }) |button| {
                const rect = try rectIn(button, hwnd);
                try std.testing.expect(rect.left >= 0 and rect.right <= client.right);
                try std.testing.expect(rect.top >= viewport.bottom and rect.bottom <= client.bottom);
            }
            try std.testing.expectEqual(active_state.viewport, c.GetParent(active_state.edits[0]));
            try std.testing.expectEqual(@as(i32, 0), c.GetScrollPos(hwnd, c.SB_VERT));
            try std.testing.expect(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE))) & c.WS_VSCROLL == 0);
            try setScrollOffset(std.math.maxInt(i32));
            const last = try rectIn(active_state.edits[count - 1], active_state.viewport);
            try std.testing.expect(last.top >= 0 and last.bottom <= layout.viewport_height);
            try std.testing.expectEqual(layout.maxOffset(), active_state.scroll_offset);
            try std.testing.expectEqual(layout.maxOffset(), c.GetScrollPos(active_state.viewport, c.SB_VERT));
        }
    }
}

test "sheet framework: overflow scroll and focus notifications leave footer fixed" {
    defer active = false;
    const hwnd = try hiddenPrompt(16, "Description with enough words to wrap " ** 20);
    defer {
        _ = c.DestroyWindow(hwnd);
        freeStateValues(&active_state);
    }
    var outer: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(hwnd, &outer) != 0);
    try std.testing.expect(c.SetWindowPos(hwnd, null, 0, 0, outer.right - outer.left, 300, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
    const before = try rectIn(c.GetDlgItem(hwnd, ok_id), hwnd);
    const layout = active_state.layout;
    try std.testing.expect(layout.maxOffset() > 0);
    var info = std.mem.zeroes(c.SCROLLINFO);
    info.cbSize = @sizeOf(c.SCROLLINFO);
    info.fMask = c.SIF_ALL;
    try std.testing.expect(c.GetScrollInfo(active_state.viewport, c.SB_VERT, &info) != 0);
    try std.testing.expectEqual(layout.extent - 1, info.nMax);
    try std.testing.expectEqual(@as(c.UINT, @intCast(layout.viewport_height)), info.nPage);

    _ = c.SendMessageW(active_state.viewport, c.WM_VSCROLL, c.SB_BOTTOM, 0);
    try std.testing.expectEqual(layout.maxOffset(), active_state.scroll_offset);
    var last = try rectIn(active_state.edits[15], active_state.viewport);
    try std.testing.expect(last.top >= 0 and last.bottom <= layout.viewport_height);
    try setScrollOffset(100);
    _ = c.SendMessageW(hwnd, c.WM_MOUSEWHEEL, @as(usize, 120) << 16, 0);
    try std.testing.expectEqual(@as(i32, 16), active_state.scroll_offset);
    _ = c.SendMessageW(hwnd, c.WM_MOUSEWHEEL, @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16, 0);
    try std.testing.expectEqual(@as(i32, 100), active_state.scroll_offset);
    _ = c.SendMessageW(active_state.viewport, c.WM_VSCROLL, c.SB_TOP, 0);
    try std.testing.expectEqual(@as(i32, 0), active_state.scroll_offset);
    // Inject the native notification without taking desktop focus.
    _ = c.SendMessageW(active_state.viewport, c.WM_COMMAND, (c.EN_SETFOCUS << 16) | (9904 + 15 * 8), @bitCast(@intFromPtr(active_state.edits[15])));
    last = try rectIn(active_state.edits[15], active_state.viewport);
    try std.testing.expect(last.top >= 0 and last.bottom <= layout.viewport_height);
    try std.testing.expectEqualDeep(before, try rectIn(c.GetDlgItem(hwnd, ok_id), hwnd));
    try std.testing.expect(c.SetWindowPos(hwnd, null, 0, 0, outer.right - outer.left, 1000, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
    try std.testing.expect(active_state.scroll_offset <= active_state.layout.maxOffset());
    try setScrollOffset(-1);
    try std.testing.expectEqual(@as(i32, 0), active_state.scroll_offset);
}

test "sheet framework: native viewport erase paints the panel into a memory bitmap" {
    defer active = false;
    const hwnd = try hiddenPrompt(1, "");
    defer {
        _ = c.DestroyWindow(hwnd);
        freeStateValues(&active_state);
    }
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    var bitmap_info = std.mem.zeroes(c.BITMAPINFO);
    bitmap_info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = active_state.layout.width;
    bitmap_info.bmiHeader.biHeight = -active_state.layout.viewport_height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    var pixels: ?*anyopaque = null;
    const bitmap = c.CreateDIBSection(dc, &bitmap_info, c.DIB_RGB_COLORS, &pixels, null, 0) orelse return error.TestBitmapCreationFailed;
    defer _ = c.DeleteObject(bitmap);
    const previous = c.SelectObject(dc, bitmap);
    defer _ = c.SelectObject(dc, previous);
    _ = c.PatBlt(dc, 0, 0, active_state.layout.width, active_state.layout.viewport_height, c.WHITENESS);
    try std.testing.expect(c.SendMessageW(active_state.viewport, c.WM_ERASEBKGND, @intFromPtr(dc), 0) != 0);
    try std.testing.expectEqual(Tokens.dialog_panel, c.GetPixel(dc, 1, 1));
    try std.testing.expectEqual(Tokens.dialog_panel, c.GetPixel(dc, active_state.layout.width - 2, active_state.layout.viewport_height - 2));
}

test "sheet framework: DPI relayout reapplies measured font geometry without presenting" {
    defer active = false;
    const hwnd = try hiddenPrompt(4, "A description that wraps at the actual content width. " ** 10);
    defer {
        _ = c.DestroyWindow(hwnd);
        freeStateValues(&active_state);
    }
    for ([_]u32{ 144, 192, 96 }) |dpi| {
        _ = c.SendMessageW(hwnd, c.WM_DPICHANGED, @as(usize, dpi) | (@as(usize, dpi) << 16), 0);
        try std.testing.expect(active_state.failure == null);
        try std.testing.expect(!active_state.closed);
        try std.testing.expectEqual(dpi, active_state.dpi);
        try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
        const font = AppFont.getForDpi(AppFont.control_size, false, dpi);
        try std.testing.expectEqual(@intFromPtr(font), @as(usize, @bitCast(c.SendMessageW(active_state.edits[0], c.WM_GETFONT, 0, 0))));
        var client: c.RECT = undefined;
        try std.testing.expect(c.GetClientRect(hwnd, &client) != 0);
        try std.testing.expectEqual(client.bottom, active_state.layout.viewport_height + Dpi.scale(56, dpi));
        const button = try rectIn(c.GetDlgItem(hwnd, ok_id), hwnd);
        try std.testing.expect(button.top >= active_state.layout.viewport_height and button.bottom <= client.bottom);
    }
}

test "sheet framework: short prompts hide scrollbar and wrapped labels use measured bounds" {
    defer active = false;
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const hwnd = try hiddenPromptForDpi(1, "", dpi);
        defer {
            _ = c.DestroyWindow(hwnd);
            freeStateValues(&active_state);
        }
        try std.testing.expectEqual(@as(i32, 0), active_state.layout.maxOffset());
        try std.testing.expect(@as(usize, @bitCast(c.GetWindowLongPtrW(active_state.viewport, c.GWL_STYLE))) & c.WS_VSCROLL == 0);
        const short_height = active_state.layout.label_height[0];
        active_state.labels[0] = "Long field label with wrapping " ** 18;
        const wide_label = try wideZ(std.testing.allocator, active_state.labels[0]);
        defer std.testing.allocator.free(wide_label);
        try std.testing.expect(c.SetWindowTextW(active_state.label_windows[0], wide_label.ptr) != 0);
        try relayout(hwnd);
        try std.testing.expect(active_state.layout.label_height[0] > short_height);
        const label = try rectIn(active_state.label_windows[0], active_state.viewport);
        const edit = try rectIn(active_state.edits[0], active_state.viewport);
        try std.testing.expect(label.bottom < edit.top);
        try std.testing.expectEqual(active_state.layout.text_width, label.right - label.left);
        try std.testing.expect(active_state.layout.maxOffset() > 0);
    }
}

test "sheet framework: child command routing preserves owned Unicode and modal outcomes" {
    defer active = false;
    for ([_]usize{ ok_id, cancel_id, c.IDCANCEL }) |command| {
        const hwnd = try hiddenPrompt(1, "");
        defer {
            _ = c.DestroyWindow(hwnd);
            freeStateValues(&active_state);
        }
        try std.testing.expect(c.SetWindowTextW(active_state.edits[0], std.unicode.utf8ToUtf16LeStringLiteral("Проекты über")) != 0);
        _ = c.SendMessageW(active_state.viewport, c.WM_COMMAND, command, 0);
        try std.testing.expect(active_state.closed);
        if (command == ok_id) {
            var result = (try finishText(&active_state)) orelse return error.ExpectedAcceptedText;
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("Проекты über", result.values[0]);
        } else {
            try std.testing.expect((try finishText(&active_state)) == null);
        }
    }
}

test "sheet framework: focus reveals an edit above scroll even with a viewport-tall label" {
    defer active = false;
    const hwnd = try hiddenPrompt(16, "");
    defer {
        _ = c.DestroyWindow(hwnd);
        freeStateValues(&active_state);
    }
    active_state.labels[0] = "Long wrapped first label " ** 500;
    try relayout(hwnd);
    try setScrollOffset(active_state.layout.maxOffset());
    const first = active_state.edits[0];
    _ = c.SendMessageW(active_state.viewport, c.WM_COMMAND, (c.EN_SETFOCUS << 16) | 9904, @bitCast(@intFromPtr(first)));
    const rect = try rectIn(first, active_state.viewport);
    try std.testing.expect(rect.top >= 0 and rect.bottom <= active_state.layout.viewport_height);
}

test "sheet framework: DPI change respects suggested position rather than recentering" {
    defer active = false;
    const hwnd = try hiddenPrompt(1, "");
    defer {
        _ = c.DestroyWindow(hwnd);
        freeStateValues(&active_state);
    }
    var monitor = std.mem.zeroes(c.MONITORINFO);
    monitor.cbSize = @sizeOf(c.MONITORINFO);
    try std.testing.expect(c.GetMonitorInfoW(c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTOPRIMARY), &monitor) != 0);
    var suggested = c.RECT{
        .left = monitor.rcWork.left + 10,
        .top = monitor.rcWork.top + 10,
        .right = monitor.rcWork.left + 570,
        .bottom = monitor.rcWork.top + 300,
    };
    _ = c.SendMessageW(hwnd, c.WM_DPICHANGED, 96 | (96 << 16), @bitCast(@intFromPtr(&suggested)));
    try std.testing.expect(active_state.failure == null);
    var actual: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(hwnd, &actual) != 0);
    try std.testing.expectEqual(suggested.left, actual.left);
    try std.testing.expectEqual(suggested.top, actual.top);
}

test "sheet framework: creation failures release partial values and controls" {
    try registerClass();
    defer active = false;
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            active_state = State{ .allocator = allocator, .parent = null, .count = 2, .description = "Description" };
            defer freeStateValues(&active_state);
            active_state.labels[0] = "First";
            active_state.labels[1] = "Second";
            active_state.values[0] = try allocator.dupe(u8, "first");
            active_state.values[1] = try allocator.dupe(u8, "second");
            active = true;
            const hwnd = createTextDialog(null, std.unicode.utf8ToUtf16LeStringLiteral("Allocation fixture")) orelse return active_state.failure orelse error.TestWindowCreationFailed;
            defer _ = c.DestroyWindow(hwnd);
            if (active_state.failure) |err| return err;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "accepted workspace text survives native edit teardown" {
    const allocator = std.testing.allocator;
    var state = State{ .allocator = allocator, .parent = null, .count = 2 };
    defer freeStateValues(&state);
    state.values[0] = try allocator.dupe(u8, "old workspace");
    state.values[1] = try allocator.dupe(u8, "old name");
    const first = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("alpha").ptr,
        0,
        0,
        0,
        100,
        20,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer if (c.IsWindow(first) != 0) {
        _ = c.DestroyWindow(first);
    };
    const second = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Проекты über").ptr,
        0,
        0,
        0,
        100,
        20,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer if (c.IsWindow(second) != 0) {
        _ = c.DestroyWindow(second);
    };
    state.edits[0] = first;
    state.edits[1] = second;
    applyTextCommand(&state, .submit);
    try std.testing.expect(c.DestroyWindow(first) != 0);
    try std.testing.expect(c.DestroyWindow(second) != 0);
    var result = (try finishText(&state)) orelse return error.ExpectedAcceptedText;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("alpha", result.values[0]);
    try std.testing.expectEqualStrings("Проекты über", result.values[1]);
    try std.testing.expectEqual(@as(usize, 0), state.count);
}

test "cancelled or closed workspace text has no accepted result" {
    for ([_]TextCommand{ .cancel, .close }) |command| {
        var state = State{
            .allocator = std.testing.allocator,
            .parent = null,
            .count = 1,
        };
        defer freeStateValues(&state);
        state.values[0] = try state.allocator.dupe(u8, "do-not-delete");
        applyTextCommand(&state, command);
        try std.testing.expect((try finishText(&state)) == null);
        try std.testing.expect(state.closed);
        try std.testing.expectEqual(@as(usize, 0), state.count);
    }
}

test "workspace text read failure never accepts stale values" {
    var state = State{
        .allocator = std.testing.allocator,
        .parent = null,
        .count = 1,
    };
    defer freeStateValues(&state);
    state.values[0] = try state.allocator.dupe(u8, "stale-name");
    applyTextCommand(&state, .submit);
    try std.testing.expect(!state.accepted);
    try std.testing.expect(state.closed);
    try std.testing.expectError(error.DialogReadFailed, finishText(&state));
    try std.testing.expectEqual(@as(usize, 0), state.count);
}

test "workspace text rejects reentrant presentation before creating any window" {
    const previous = active;
    active = true;
    defer active = previous;
    try std.testing.expectError(error.DialogAlreadyOpen, textWithDescription(
        null,
        std.testing.allocator,
        "New Workspace",
        "",
        &.{"Name"},
        &.{""},
    ));
}

test "workspace text capture and transfer release every partial allocation" {
    const edit = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("new workspace").ptr,
        0,
        0,
        0,
        100,
        20,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer _ = c.DestroyWindow(edit);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, window: c.HWND) !void {
            var state = State{ .allocator = allocator, .parent = null, .count = 2 };
            defer freeStateValues(&state);
            state.values[0] = try allocator.dupe(u8, "old first");
            state.values[1] = try allocator.dupe(u8, "old second");
            state.edits[0] = window;
            state.edits[1] = window;
            applyTextCommand(&state, .submit);
            var result = (try finishText(&state)) orelse return error.ExpectedAcceptedText;
            defer result.deinit(allocator);
            try std.testing.expectEqualStrings("new workspace", result.values[0]);
            try std.testing.expectEqualStrings("new workspace", result.values[1]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{edit});
}

test "text dialog opens with keyboard focus in its first field, text selected, and keeps it across activation" {
    // Dev Box beta17: Rename Loop opened with focus on the dialog frame, so typing did
    // nothing until the Title edit was clicked.
    const allocator = std.testing.allocator;
    const previous_active = active;
    active_state = State{ .allocator = allocator, .parent = null, .count = 1, .description = "Shown on the loop card." };
    active_state.labels[0] = "Title";
    active_state.values[0] = try allocator.dupe(u8, "GCQCrud17");
    active = true;
    defer {
        freeStateValues(&active_state);
        active = previous_active;
    }
    try registerClass();
    const wide_title = try wideZ(allocator, "Rename Loop");
    defer allocator.free(wide_title);
    const hwnd = createTextDialog(null, wide_title) orelse return error.TestWindowCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    const title_edit = active_state.edits[0] orelse return error.TestWindowCreationFailed;
    try std.testing.expectEqual(@as(isize, 9904), c.GetDlgCtrlID(title_edit));

    presentDialog(hwnd);
    try std.testing.expectEqual(title_edit, c.GetFocus());
    var start: c.DWORD = 0;
    var end: c.DWORD = 0;
    _ = c.SendMessageW(title_edit, c.EM_GETSEL, @intFromPtr(&start), @bitCast(@intFromPtr(&end)));
    try std.testing.expectEqual(@as(c.DWORD, 0), start);
    try std.testing.expectEqual(@as(c.DWORD, "GCQCrud17".len), end);

    // Activation hands focus to the frame (DefWindowProc's WM_ACTIVATE does exactly
    // that); the frame must pass it straight back to the field the user was in.
    _ = c.SendMessageW(hwnd, c.WM_ACTIVATE, c.WA_INACTIVE, 0);
    _ = c.SetFocus(hwnd);
    try std.testing.expectEqual(title_edit, c.GetFocus());
    _ = c.SendMessageW(hwnd, c.WM_ACTIVATE, c.WA_ACTIVE, 0);
    try std.testing.expectEqual(title_edit, c.GetFocus());
}

fn openProbeDialog(allocator: std.mem.Allocator, initial: []const u8) !c.HWND {
    active_state = State{ .allocator = allocator, .parent = null, .count = 1 };
    active_state.labels[0] = "Title";
    active_state.values[0] = try allocator.dupe(u8, initial);
    active = true;
    try registerClass();
    const wide_title = try wideZ(allocator, "Rename Loop");
    defer allocator.free(wide_title);
    const hwnd = createTextDialog(null, wide_title) orelse return error.TestWindowCreationFailed;
    presentDialog(hwnd);
    return hwnd;
}

/// Delivers one key the way the modal loop does: through IsDialogMessageW to the
/// focused control, falling back to the ordinary translate/dispatch path.
fn pumpKey(hwnd: c.HWND, target: c.HWND, key: usize) void {
    var message = std.mem.zeroes(c.MSG);
    message.hwnd = target;
    message.message = c.WM_KEYDOWN;
    message.wParam = key;
    if (c.IsDialogMessageW(hwnd, &message) != 0) return;
    _ = c.TranslateMessage(&message);
    _ = c.DispatchMessageW(&message);
}

fn typeInto(edit: c.HWND, text_utf8: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, text_utf8);
    defer std.testing.allocator.free(wide);
    _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
    for (wide) |unit| _ = c.SendMessageW(edit, c.WM_CHAR, unit, 0);
}

test "Enter in a focused single-line field submits the dialog with the typed text" {
    // Dev Box beta18: Enter in Rename Loop's Title field did nothing, so the dialog
    // could only be accepted by clicking OK.
    const allocator = std.testing.allocator;
    const previous_active = active;
    defer active = previous_active;
    const hwnd = try openProbeDialog(allocator, "GCQCrud17");
    defer {
        freeStateValues(&active_state);
        _ = c.DestroyWindow(hwnd);
    }
    const edit = active_state.edits[0] orelse return error.TestWindowCreationFailed;
    try std.testing.expectEqual(edit, c.GetFocus());
    try typeInto(edit, "Renamed loop");

    pumpKey(hwnd, edit, c.VK_RETURN);

    try std.testing.expect(active_state.closed);
    try std.testing.expect(active_state.accepted);
    var result = (try finishText(&active_state)) orelse return error.ExpectedAcceptedText;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqualStrings("Renamed loop", result.values[0]);
}

test "Escape in a focused field cancels the dialog without a result" {
    const allocator = std.testing.allocator;
    const previous_active = active;
    defer active = previous_active;
    const hwnd = try openProbeDialog(allocator, "keep me");
    defer {
        freeStateValues(&active_state);
        _ = c.DestroyWindow(hwnd);
    }
    const edit = active_state.edits[0] orelse return error.TestWindowCreationFailed;
    try typeInto(edit, "discarded");

    pumpKey(hwnd, edit, c.VK_ESCAPE);

    try std.testing.expect(active_state.closed);
    try std.testing.expect(!active_state.accepted);
    try std.testing.expect((try finishText(&active_state)) == null);
}

test "Enter on the Cancel button cancels rather than submitting" {
    const allocator = std.testing.allocator;
    const previous_active = active;
    defer active = previous_active;
    const hwnd = try openProbeDialog(allocator, "keep me");
    defer {
        freeStateValues(&active_state);
        _ = c.DestroyWindow(hwnd);
    }
    const cancel = c.GetDlgItem(hwnd, cancel_id) orelse return error.TestWindowCreationFailed;
    _ = c.SetFocus(cancel);

    pumpKey(hwnd, cancel, c.VK_RETURN);

    try std.testing.expect(active_state.closed);
    try std.testing.expect(!active_state.accepted);
}

test "dialog exposes OK as its single default button" {
    const allocator = std.testing.allocator;
    const previous_active = active;
    defer active = previous_active;
    const hwnd = try openProbeDialog(allocator, "x");
    defer {
        freeStateValues(&active_state);
        _ = c.DestroyWindow(hwnd);
    }
    const reply: usize = @bitCast(c.SendMessageW(hwnd, c.DM_GETDEFID, 0, 0));
    try std.testing.expectEqual(@as(usize, c.DC_HASDEFID), reply >> 16);
    try std.testing.expectEqual(@as(usize, ok_id), reply & 0xffff);
    const ok = c.GetDlgItem(hwnd, ok_id) orelse return error.TestWindowCreationFailed;
    const cancel = c.GetDlgItem(hwnd, cancel_id) orelse return error.TestWindowCreationFailed;
    const style_mask: usize = 0xf;
    try std.testing.expectEqual(@as(usize, c.BS_DEFPUSHBUTTON), @as(usize, @bitCast(c.GetWindowLongPtrW(ok, c.GWL_STYLE))) & style_mask);
    try std.testing.expectEqual(@as(usize, c.BS_PUSHBUTTON), @as(usize, @bitCast(c.GetWindowLongPtrW(cancel, c.GWL_STYLE))) & style_mask);
}
