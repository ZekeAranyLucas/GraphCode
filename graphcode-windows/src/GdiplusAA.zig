// Minimal GDI+ "flat" C-API bindings used solely to anti-alias the graph
// canvas's line/curve/rounded-rect drawing. Classic GDI pens created via
// CreatePen are never anti-aliased, which is a primary cause of edges,
// connectors, and selection rings looking visibly "jaggier" on Windows
// than the same shapes rendered by macOS's Core Graphics (which
// anti-aliases by default). GDI+ is a standard, always-present Windows
// component (gdiplus.dll) that supports SmoothingMode::AntiAlias without
// requiring a larger Direct2D migration.
//
// This module is intentionally small and defensive: every draw call
// gracefully no-ops (returning false) if GDI+ failed to initialize or if
// any GDI+ call fails, so every call site retains its original plain-GDI
// fallback path and this cannot regress or destabilize existing rendering.
const std = @import("std");
const c = @import("Win32.zig").c;

const GpStatus = c_int;
const Ok: GpStatus = 0;

const GpGraphics = opaque {};
const GpPen = opaque {};
const GpPath = opaque {};
const GpBrush = opaque {};
const GpBitmap = opaque {};
const GpRectF = extern struct { x: f32, y: f32, width: f32, height: f32 };

const SmoothingModeAntiAlias: c_int = 4;
const UnitPixel: c_int = 2;
const FillModeAlternate: c_int = 0;

const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32 = 1,
    DebugEventCallback: ?*anyopaque = null,
    SuppressBackgroundThread: c.BOOL = 0,
    SuppressExternalCodecs: c.BOOL = 0,
};

extern "gdiplus" fn GdiplusStartup(
    token: *usize,
    input: *const GdiplusStartupInput,
    output: ?*anyopaque,
) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdiplusShutdown(token: usize) callconv(.winapi) void;
extern "gdiplus" fn GdipCreateFromHDC(hdc: c.HDC, graphics: **GpGraphics) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeleteGraphics(graphics: *GpGraphics) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipSetSmoothingMode(graphics: *GpGraphics, mode: c_int) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreatePen1(color: u32, width: f32, unit: c_int, pen: **GpPen) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeletePen(pen: *GpPen) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDrawLineI(graphics: *GpGraphics, pen: *GpPen, x1: c_int, y1: c_int, x2: c_int, y2: c_int) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDrawBezierI(
    graphics: *GpGraphics,
    pen: *GpPen,
    x1: c_int,
    y1: c_int,
    x2: c_int,
    y2: c_int,
    x3: c_int,
    y3: c_int,
    x4: c_int,
    y4: c_int,
) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreatePath(brush_mode: c_int, path: **GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeletePath(path: *GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipAddPathArcI(path: *GpPath, x: c_int, y: c_int, width: c_int, height: c_int, start_angle: f32, sweep_angle: f32) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipClosePathFigure(path: *GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDrawPath(graphics: *GpGraphics, pen: *GpPen, path: *GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipFillPath(graphics: *GpGraphics, brush: *GpBrush, path: *GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreateSolidFill(color: u32, brush: **GpBrush) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeleteBrush(brush: *GpBrush) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipSetPageUnit(graphics: *GpGraphics, unit: c_int) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipSetClipHrgn(graphics: *GpGraphics, region: c.HRGN, mode: c_int) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipSetClipPath(graphics: *GpGraphics, path: *GpPath, mode: c_int) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipSaveGraphics(graphics: *GpGraphics, state: *u32) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipRestoreGraphics(graphics: *GpGraphics, state: u32) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreateLineBrushFromRect(bounds: *const GpRectF, top: u32, bottom: u32, mode: c_int, wrap: c_int, brush: **GpBrush) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipFillRectangleI(graphics: *GpGraphics, brush: *GpBrush, x: i32, y: i32, width: i32, height: i32) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipSetPenDashArray(pen: *GpPen, pattern: [*]const f32, count: c_int) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreateBitmapFromScan0(width: i32, height: i32, stride: i32, format: c_int, pixels: [*]u8, bitmap: **GpBitmap) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDisposeImage(bitmap: *GpBitmap) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDrawImageRect(graphics: *GpGraphics, bitmap: *GpBitmap, x: f32, y: f32, width: f32, height: f32) callconv(.winapi) GpStatus;

var startup_mutex: std.Thread.Mutex = .{};
var startup_token: usize = 0;
var available: bool = false;
var start_attempted: bool = false;
var shutdown_requested: bool = false;
var readiness_test_entered: c.HANDLE = null;
var readiness_test_release: c.HANDLE = null;
var readiness_test_finished: c.HANDLE = null;
const readiness_test_timeout_ms: c.DWORD = 2_000;

const SystemStartup = struct {
    pub fn run() ?usize {
        var token: usize = 0;
        var input = GdiplusStartupInput{};
        if (GdiplusStartup(&token, &input, null) != Ok) return null;
        return token;
    }
};

/// Starts optional GDI+ initialization away from the UI thread. Until the
/// worker succeeds, every draw call returns false and the caller uses plain GDI.
pub fn init() void {
    initWith(SystemStartup);
}

pub fn initWith(comptime Startup: type) void {
    startup_mutex.lock();
    if (start_attempted or shutdown_requested) {
        startup_mutex.unlock();
        return;
    }
    start_attempted = true;
    startup_mutex.unlock();

    const Worker = struct {
        fn run() void {
            const token = Startup.run() orelse return;
            startup_mutex.lock();
            if (shutdown_requested) {
                startup_mutex.unlock();
                GdiplusShutdown(token);
                return;
            }
            startup_token = token;
            available = true;
            startup_mutex.unlock();
        }
    };
    var worker = std.Thread.spawn(.{}, Worker.run, .{}) catch return;
    worker.detach();
}

pub fn isReady() bool {
    startup_mutex.lock();
    defer startup_mutex.unlock();
    return available;
}

/// Prevents new GDI+ sessions and releases a completed process-global startup.
/// A worker still blocked inside Windows remains detached and cannot delay exit.
pub fn deinit() void {
    startup_mutex.lock();
    shutdown_requested = true;
    if (!available) {
        startup_mutex.unlock();
        return;
    }
    available = false;
    const token = startup_token;
    startup_token = 0;
    startup_mutex.unlock();
    GdiplusShutdown(token);
}

fn colorrefToArgb(colorref: u32) u32 {
    const r = colorref & 0xFF;
    const g = (colorref >> 8) & 0xFF;
    const b = (colorref >> 16) & 0xFF;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

const Session = struct {
    graphics: *GpGraphics,
    pen: *GpPen,
};

fn beginSession(hdc: c.HDC, colorref: u32, width: f32) ?Session {
    startup_mutex.lock();
    if (!available) {
        startup_mutex.unlock();
        return null;
    }
    var graphics: *GpGraphics = undefined;
    if (GdipCreateFromHDC(hdc, &graphics) != Ok) {
        startup_mutex.unlock();
        return null;
    }
    if (GdipSetSmoothingMode(graphics, SmoothingModeAntiAlias) != Ok) {
        _ = GdipDeleteGraphics(graphics);
        startup_mutex.unlock();
        return null;
    }
    var pen: *GpPen = undefined;
    if (GdipCreatePen1(colorrefToArgb(colorref), width, UnitPixel, &pen) != Ok) {
        _ = GdipDeleteGraphics(graphics);
        startup_mutex.unlock();
        return null;
    }
    return .{ .graphics = graphics, .pen = pen };
}

fn endSession(session: Session) void {
    _ = GdipDeletePen(session.pen);
    _ = GdipDeleteGraphics(session.graphics);
    startup_mutex.unlock();
}

/// Draws an anti-aliased straight line. Returns false (drawing nothing)
/// if GDI+ is unavailable so the caller can fall back to CreatePen/LineTo.
pub fn drawLine(hdc: c.HDC, x1: i32, y1: i32, x2: i32, y2: i32, colorref: u32, width: f32) bool {
    const session = beginSession(hdc, colorref, width) orelse return false;
    defer endSession(session);
    return GdipDrawLineI(session.graphics, session.pen, x1, y1, x2, y2) == Ok;
}

/// Draws an anti-aliased cubic Bezier curve (the same 4-point control
/// convention as Win32's PolyBezier for a single segment).
pub fn drawBezier(
    hdc: c.HDC,
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    x3: i32,
    y3: i32,
    x4: i32,
    y4: i32,
    colorref: u32,
    width: f32,
) bool {
    const session = beginSession(hdc, colorref, width) orelse return false;
    defer endSession(session);
    return GdipDrawBezierI(session.graphics, session.pen, x1, y1, x2, y2, x3, y3, x4, y4) == Ok;
}

fn buildRoundedRectPath(x: i32, y: i32, width: i32, height: i32, radius: i32) ?*GpPath {
    var path: *GpPath = undefined;
    if (GdipCreatePath(FillModeAlternate, &path) != Ok) return null;
    const d = radius * 2;
    const right = x + width;
    const bottom = y + height;
    var ok = true;
    ok = ok and GdipAddPathArcI(path, x, y, d, d, 180, 90) == Ok;
    ok = ok and GdipAddPathArcI(path, right - d, y, d, d, 270, 90) == Ok;
    ok = ok and GdipAddPathArcI(path, right - d, bottom - d, d, d, 0, 90) == Ok;
    ok = ok and GdipAddPathArcI(path, x, bottom - d, d, d, 90, 90) == Ok;
    ok = ok and GdipClosePathFigure(path) == Ok;
    if (!ok) {
        _ = GdipDeletePath(path);
        return null;
    }
    return path;
}

/// Draws an anti-aliased filled-and-stroked rounded rectangle, replacing
/// GDI's `RoundRect` (whose curved corners are never anti-aliased) for the
/// graph canvas's node cards and selection rings. Returns false if GDI+
/// drawing failed at any step, in which case the caller should fall back
/// to the original `CreateSolidBrush` + `CreatePen` + `RoundRect` path.
pub fn drawRoundedRect(
    hdc: c.HDC,
    bounds: c.RECT,
    radius: i32,
    fill_colorref: u32,
    border_colorref: u32,
    border_width: f32,
) bool {
    startup_mutex.lock();
    defer startup_mutex.unlock();
    if (!available) return false;
    var graphics: *GpGraphics = undefined;
    if (GdipCreateFromHDC(hdc, &graphics) != Ok) return false;
    defer _ = GdipDeleteGraphics(graphics);
    if (GdipSetSmoothingMode(graphics, SmoothingModeAntiAlias) != Ok) return false;

    const width = bounds.right - bounds.left;
    const height = bounds.bottom - bounds.top;
    const clamped_radius = @min(radius, @divTrunc(@min(width, height), 2));
    const path = buildRoundedRectPath(bounds.left, bounds.top, width, height, clamped_radius) orelse return false;
    defer _ = GdipDeletePath(path);

    var brush: *GpBrush = undefined;
    if (GdipCreateSolidFill(colorrefToArgb(fill_colorref), &brush) != Ok) return false;
    defer _ = GdipDeleteBrush(brush);
    if (GdipFillPath(graphics, brush, path) != Ok) return false;

    var pen: *GpPen = undefined;
    if (GdipCreatePen1(colorrefToArgb(border_colorref), border_width, UnitPixel, &pen) != Ok) return false;
    defer _ = GdipDeletePen(pen);
    return GdipDrawPath(graphics, pen, path) == Ok;
}

pub const LoopCardChrome = struct {
    top: u32,
    bottom: u32,
    radius: i32,
    stripe_width: i32,
    stripe: u32,
    stripe_alpha: u8,
    border: u32,
    border_alpha: u8,
    border_width: f32,
    dashed: bool,
    halo: u32,
    halo_opacity: f32,
    halo_sigma: f32,
    zoom: f32,
};

fn chromeStatus(status: GpStatus) !void {
    if (status != Ok) {
        std.log.warn("Loop card GDI+ operation failed with status {d}", .{status});
        return error.LoopCardGdiplusOperationFailed;
    }
}

fn alphaArgb(color: u32, alpha: u8) u32 {
    return (colorrefToArgb(color) & 0x00FFFFFF) | (@as(u32, alpha) << 24);
}

fn chromeGraphics(hdc: c.HDC) !*GpGraphics {
    var graphics: *GpGraphics = undefined;
    try chromeStatus(GdipCreateFromHDC(hdc, &graphics));
    errdefer _ = GdipDeleteGraphics(graphics);
    try chromeStatus(GdipSetPageUnit(graphics, UnitPixel));
    try chromeStatus(GdipSetSmoothingMode(graphics, SmoothingModeAntiAlias));
    const region = c.CreateRectRgn(0, 0, 0, 0) orelse return error.LoopCardClipAllocationFailed;
    defer _ = c.DeleteObject(region);
    const has_clip = c.GetClipRgn(hdc, region);
    if (has_clip == -1) return error.LoopCardClipReadFailed;
    // CreateFromHDC already carries the HDC's logical-to-device mapping.
    // HRGNs are device-space; no second world transform is applied.
    if (has_clip == 1) try chromeStatus(GdipSetClipHrgn(graphics, region, 0));
    return graphics;
}

const ChromeMask = struct {
    alpha: []f32,
    width: usize,
    height: usize,
    padding: i32,

    fn init(allocator: std.mem.Allocator, width: i32, height: i32, radius: i32, sigma: f32) !ChromeMask {
        if (width <= 0 or height <= 0 or width > 4096 or height > 4096 or radius < 0 or
            !std.math.isFinite(sigma) or sigma <= 0 or sigma > 128)
            return error.LoopCardShadowDimensionsInvalid;
        // A finite, normalized Gaussian; sigma maps the declared logical shadow radius.
        // SwiftUI's exact kernel/compositing equivalence remains a visual-review question.
        const support: i32 = @intFromFloat(@ceil(3 * sigma));
        const padding = support + 1;
        const w: usize = @intCast(width + padding * 2);
        const h: usize = @intCast(height + padding * 2);
        const alpha = try allocator.alloc(f32, w * h);
        errdefer allocator.free(alpha);
        const scratch = try allocator.alloc(f32, w * h);
        defer allocator.free(scratch);
        const kernel = try allocator.alloc(f32, @intCast(support * 2 + 1));
        defer allocator.free(kernel);
        var total: f32 = 0;
        for (kernel, 0..) |*weight, index| {
            const distance = @as(f32, @floatFromInt(@as(i32, @intCast(index)) - support)) / sigma;
            weight.* = @exp(-0.5 * distance * distance);
            total += weight.*;
        }
        for (kernel) |*weight| weight.* /= total;
        const r: f32 = @floatFromInt(@min(radius, @divTrunc(@min(width, height), 2)));
        for (0..h) |y| {
            for (0..w) |x| {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - @as(f32, @floatFromInt(padding));
                const py = @as(f32, @floatFromInt(y)) + 0.5 - @as(f32, @floatFromInt(padding));
                const inside = px >= 0 and px < @as(f32, @floatFromInt(width)) and
                    py >= 0 and py < @as(f32, @floatFromInt(height));
                const dx = px - std.math.clamp(px, r, @as(f32, @floatFromInt(width)) - r);
                const dy = py - std.math.clamp(py, r, @as(f32, @floatFromInt(height)) - r);
                alpha[y * w + x] = if (inside and dx * dx + dy * dy <= r * r) 1 else 0;
            }
        }
        const reach: usize = @intCast(support);
        for (0..h) |y| {
            for (0..w) |x| {
                var sum: f32 = 0;
                for (x -| reach..@min(w, x + reach + 1)) |source_x| {
                    sum += alpha[y * w + source_x] * kernel[source_x + reach - x];
                }
                scratch[y * w + x] = sum;
            }
        }
        for (0..h) |y| {
            for (0..w) |x| {
                var sum: f32 = 0;
                for (y -| reach..@min(h, y + reach + 1)) |source_y| {
                    sum += scratch[source_y * w + x] * kernel[source_y + reach - y];
                }
                alpha[y * w + x] = sum;
            }
        }
        return .{ .alpha = alpha, .width = w, .height = h, .padding = padding };
    }

    fn deinit(self: ChromeMask, allocator: std.mem.Allocator) void {
        allocator.free(self.alpha);
    }
};

fn chromePremultiplied(color: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    const r = ((color & 255) * a + 127) / 255;
    const g = (((color >> 8) & 255) * a + 127) / 255;
    const b = (((color >> 16) & 255) * a + 127) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

const ChromeShadow = struct {
    bitmap: *GpBitmap,
    pixels: []u32,
    width: i32,
    height: i32,
    padding: i32,

    fn init(allocator: std.mem.Allocator, width: i32, height: i32, radius: i32, sigma: f32, color: u32, opacity: f32) !ChromeShadow {
        if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.LoopCardShadowOpacityInvalid;
        const mask = try ChromeMask.init(allocator, width, height, radius, sigma);
        defer mask.deinit(allocator);
        const pixels = try allocator.alloc(u32, mask.alpha.len);
        errdefer allocator.free(pixels);
        for (pixels, mask.alpha) |*pixel, coverage| {
            const alpha: u8 = @intFromFloat(@round(std.math.clamp(coverage * opacity, 0, 1) * 255));
            pixel.* = chromePremultiplied(color, alpha);
        }
        var bitmap: *GpBitmap = undefined;
        const w: i32 = @intCast(mask.width);
        const h: i32 = @intCast(mask.height);
        try chromeStatus(GdipCreateBitmapFromScan0(w, h, w * 4, 0x000E200B, @ptrCast(pixels.ptr), &bitmap));
        return .{ .bitmap = bitmap, .pixels = pixels, .width = w, .height = h, .padding = mask.padding };
    }

    fn deinit(self: ChromeShadow, allocator: std.mem.Allocator) void {
        _ = GdipDisposeImage(self.bitmap);
        allocator.free(self.pixels);
    }

    fn draw(self: ChromeShadow, graphics: *GpGraphics, bounds: c.RECT, offset_y: f32) !void {
        try chromeStatus(GdipDrawImageRect(
            graphics, self.bitmap,
            @floatFromInt(bounds.left - self.padding),
            @as(f32, @floatFromInt(bounds.top - self.padding)) + offset_y,
            @floatFromInt(self.width), @floatFromInt(self.height),
        ));
    }
};

pub fn drawLoopCardChrome(hdc: c.HDC, bounds: c.RECT, style: LoopCardChrome) !void {
    startup_mutex.lock();
    defer startup_mutex.unlock();
    if (!available) return error.LoopCardGdiplusUnavailable;
    try drawLoopCardFaceReady(hdc, bounds, style);
}

pub fn drawLoopCardShadows(hdc: c.HDC, allocator: std.mem.Allocator, bounds: c.RECT, style: LoopCardChrome) !void {
    startup_mutex.lock();
    defer startup_mutex.unlock();
    if (!available) return error.LoopCardGdiplusUnavailable;
    try drawLoopCardShadowsReady(hdc, allocator, bounds, style);
}

fn chromeDimensions(bounds: c.RECT, style: LoopCardChrome) !struct { width: i32, height: i32 } {
    const width = std.math.cast(i32, @as(i64, bounds.right) - bounds.left) orelse return error.LoopCardBoundsInvalid;
    const height = std.math.cast(i32, @as(i64, bounds.bottom) - bounds.top) orelse return error.LoopCardBoundsInvalid;
    if (width <= 0 or height <= 0 or !std.math.isFinite(style.zoom) or style.zoom <= 0 or
        !std.math.isFinite(style.border_width) or style.border_width <= 0 or
        style.stripe_width <= 0 or style.stripe_width > width)
        return error.LoopCardBoundsInvalid;
    return .{ .width = width, .height = height };
}

fn drawLoopCardChromeReady(hdc: c.HDC, allocator: std.mem.Allocator, bounds: c.RECT, style: LoopCardChrome) !void {
    try drawLoopCardShadowsReady(hdc, allocator, bounds, style);
    try drawLoopCardFaceReady(hdc, bounds, style);
}

fn drawLoopCardShadowsReady(hdc: c.HDC, allocator: std.mem.Allocator, bounds: c.RECT, style: LoopCardChrome) !void {
    const dimensions = try chromeDimensions(bounds, style);
    const width = dimensions.width;
    const height = dimensions.height;
    const halo = try ChromeShadow.init(allocator, width, height, style.radius, style.halo_sigma, style.halo, style.halo_opacity);
    defer halo.deinit(allocator);
    const ambient = try ChromeShadow.init(allocator, width, height, style.radius, 10 * style.zoom, 0, 0.30);
    defer ambient.deinit(allocator);
    const contact = try ChromeShadow.init(allocator, width, height, style.radius, 2 * style.zoom, 0, 0.45);
    defer contact.deinit(allocator);
    const graphics = try chromeGraphics(hdc);
    defer _ = GdipDeleteGraphics(graphics);
    try halo.draw(graphics, bounds, 0);
    try ambient.draw(graphics, bounds, 5 * style.zoom);
    try contact.draw(graphics, bounds, style.zoom);
    if (@import("builtin").is_test) std.debug.print("loop-card-native-aa shadows=ok\n", .{});
}

fn drawLoopCardFaceReady(hdc: c.HDC, bounds: c.RECT, style: LoopCardChrome) !void {
    const dimensions = try chromeDimensions(bounds, style);
    const width = dimensions.width;
    const height = dimensions.height;
    const graphics = try chromeGraphics(hdc);
    defer _ = GdipDeleteGraphics(graphics);
    const path = buildRoundedRectPath(bounds.left, bounds.top, width, height, style.radius) orelse return error.LoopCardPathCreationFailed;
    defer _ = GdipDeletePath(path);
    var gradient: *GpBrush = undefined;
    const face = GpRectF{ .x = @floatFromInt(bounds.left), .y = @floatFromInt(bounds.top), .width = @floatFromInt(width), .height = @floatFromInt(height) };
    try chromeStatus(GdipCreateLineBrushFromRect(&face, colorrefToArgb(style.top), colorrefToArgb(style.bottom), 1, 3, &gradient));
    defer _ = GdipDeleteBrush(gradient);
    var stripe: *GpBrush = undefined;
    try chromeStatus(GdipCreateSolidFill(alphaArgb(style.stripe, style.stripe_alpha), &stripe));
    defer _ = GdipDeleteBrush(stripe);
    var border: *GpPen = undefined;
    try chromeStatus(GdipCreatePen1(alphaArgb(style.border, style.border_alpha), style.border_width, 0, &border));
    defer _ = GdipDeletePen(border);
    if (style.dashed) {
        const pattern = [_]f32{ 4, 3 };
        try chromeStatus(GdipSetPenDashArray(border, &pattern, pattern.len));
    }
    try chromeStatus(GdipFillPath(graphics, gradient, path));
    try chromeStatus(GdipDrawPath(graphics, border, path));
    var clip_state: u32 = undefined;
    try chromeStatus(GdipSaveGraphics(graphics, &clip_state));
    try chromeStatus(GdipSetClipPath(graphics, path, 1));
    // Baseline FillRect covers the left border, with an opaque face under unwired alpha.
    // Aliased rectangle coverage follows that device footprint; the rounded clip remains.
    try chromeStatus(GdipSetSmoothingMode(graphics, 3));
    try chromeStatus(GdipFillRectangleI(graphics, gradient, bounds.left, bounds.top, style.stripe_width, height));
    try chromeStatus(GdipFillRectangleI(graphics, stripe, bounds.left, bounds.top, style.stripe_width, height));
    try chromeStatus(GdipRestoreGraphics(graphics, clip_state));
    if (@import("builtin").is_test) std.debug.print("loop-card-native-aa draw=ok\n", .{});
}

test "loop card chrome bounded Gaussian preserves mass symmetry and transparent support" {
    const allocator = std.testing.allocator;
    const mask = try ChromeMask.init(allocator, 40, 20, 5, 4);
    defer mask.deinit(allocator);
    var mass: f64 = 0;
    for (0..mask.height) |y| {
        for (0..mask.width) |x| {
            const alpha = mask.alpha[y * mask.width + x];
            try std.testing.expect(alpha >= 0 and alpha <= 1.000001);
            try std.testing.expectApproxEqAbs(alpha, mask.alpha[y * mask.width + mask.width - 1 - x], 0.000001);
            try std.testing.expectApproxEqAbs(alpha, mask.alpha[(mask.height - 1 - y) * mask.width + x], 0.000001);
            mass += alpha;
            if (x == 0 or y == 0 or x == mask.width - 1 or y == mask.height - 1)
                try std.testing.expectEqual(@as(f32, 0), alpha);
        }
    }
    try std.testing.expect(mass > 750 and mass < 800);
    const center_x = mask.width / 2;
    const edge_y: usize = @intCast(mask.padding);
    try std.testing.expect(mask.alpha[(edge_y - 2) * mask.width + center_x] > mask.alpha[(edge_y - 6) * mask.width + center_x]);
}

test "loop card chrome premultiplication keeps channels bounded by alpha" {
    try std.testing.expectEqual(@as(u32, 0), chromePremultiplied(0x00FFFFFF, 0));
    try std.testing.expectEqual(@as(u32, 0x80402010), chromePremultiplied(0x00204080, 128));
    try std.testing.expectEqual(@as(u32, 0x170A9FFF), alphaArgb(0x00FF9F0A, 23));
    try std.testing.expectError(error.LoopCardShadowDimensionsInvalid, ChromeMask.init(std.testing.allocator, 0, 20, 5, 4));
}

test "loop card chrome native mapped gradient stripe and caller clip" {
    const native = std.process.getEnvVarOwned(std.testing.allocator, "GRAPHCODE_NATIVE_PAINT_TESTS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(native);
    if (!std.mem.eql(u8, native, "1")) return error.LoopCardNativeTestFlagInvalid;
    const token = SystemStartup.run() orelse return error.LoopCardNativeTestStartupFailed;
    defer GdiplusShutdown(token);
    const dc = c.CreateCompatibleDC(null) orelse return error.LoopCardNativeTestDcFailed;
    defer _ = c.DeleteDC(dc);
    var info = std.mem.zeroes(c.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = 192;
    info.bmiHeader.biHeight = -128;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = c.BI_RGB;
    var storage: ?*anyopaque = null;
    const bitmap = c.CreateDIBSection(dc, &info, c.DIB_RGB_COLORS, &storage, null, 0) orelse return error.LoopCardNativeTestBitmapFailed;
    defer _ = c.DeleteObject(bitmap);
    const old = c.SelectObject(dc, bitmap) orelse return error.LoopCardNativeTestSelectFailed;
    defer _ = c.SelectObject(dc, old);
    const pixels: [*]u32 = @ptrCast(@alignCast(storage orelse return error.LoopCardNativeTestStorageFailed));
    @memset(pixels[0 .. 192 * 128], 0x00404040);
    if (c.SetMapMode(dc, c.MM_ANISOTROPIC) == 0 or c.SetWindowExtEx(dc, 96, 96, null) == 0 or
        c.SetViewportExtEx(dc, 192, 192, null) == 0)
        return error.LoopCardNativeTestMappingFailed;
    if (c.IntersectClipRect(dc, 0, 0, 80, 60) == c.ERROR) return error.LoopCardNativeTestClipFailed;
    try drawLoopCardChromeReady(dc, std.testing.allocator, .{ .left = 10, .top = 10, .right = 50, .bottom = 34 }, .{
        .top = 0x003C3C3C, .bottom = 0x00141414, .radius = 5, .stripe_width = 2,
        .stripe = 0x0000FF00, .stripe_alpha = 255, .border = 0x00FFFFFF, .border_alpha = 23,
        .border_width = 1, .dashed = false, .halo = 0x0000FF00, .halo_opacity = 0.16,
        .halo_sigma = 12, .zoom = 1,
    });
    if (c.GdiFlush() == 0) return error.LoopCardNativeTestFlushFailed;
    try std.testing.expectEqual(@as(u32, 0x0000FF00), c.GetPixel(dc, 11, 20));
    const top = c.GetPixel(dc, 46, 16) & 255;
    const bottom = c.GetPixel(dc, 46, 28) & 255;
    try std.testing.expect(top > bottom + 10);
    try std.testing.expect(c.GetPixel(dc, 10, 10) != 0x0000FF00);
    try std.testing.expectEqual(@as(u32, 0x00404040), pixels[40 * 192 + 180]);
    var extent: c.SIZE = undefined;
    if (c.GetViewportExtEx(dc, &extent) == 0) return error.LoopCardNativeTestMappingReadFailed;
    try std.testing.expectEqual(@as(c.LONG, 192), extent.cx);
    var clip: c.RECT = undefined;
    if (c.GetClipBox(dc, &clip) == c.ERROR) return error.LoopCardNativeTestClipReadFailed;
    try std.testing.expectEqual(@as(c.LONG, 80), clip.right);
    try std.testing.expectEqual(@as(c.LONG, 60), clip.bottom);
}

test "colorrefToArgb preserves channel order" {
    // COLORREF 0x00BBGGRR -> ARGB 0xAARRGGBB with full alpha.
    // 0x007AB8FF is B=0x7A, G=0xB8, R=0xFF, so ARGB is 0xFF (alpha) FF (R) B8 (G) 7A (B).
    try std.testing.expectEqual(@as(u32, 0xFFFFB87A), colorrefToArgb(0x007AB8FF));
}

const ReadinessGatedStartup = struct {
    pub fn run() ?usize {
        defer _ = c.SetEvent(readiness_test_finished);
        if (c.SetEvent(readiness_test_entered) == 0) return null;
        if (c.WaitForSingleObject(readiness_test_release, readiness_test_timeout_ms) != c.WAIT_OBJECT_0) {
            return null;
        }
        return SystemStartup.run();
    }
};

test "readiness: gated native startup publishes only after release" {
    const entered = c.CreateEventW(null, 1, 0, null) orelse return error.ReadinessEnteredEventCreationFailed;
    var release: c.HANDLE = null;
    var finished: c.HANDLE = null;
    var handles_published = false;
    var worker_may_run = false;
    defer {
        const worker_quiesced = if (worker_may_run) blk: {
            _ = c.SetEvent(release);
            deinit();
            break :blk c.WaitForSingleObject(finished, readiness_test_timeout_ms) == c.WAIT_OBJECT_0;
        } else true;
        if (worker_quiesced) {
            if (handles_published) {
                readiness_test_finished = null;
                readiness_test_release = null;
                readiness_test_entered = null;
            }
            if (finished) |handle| _ = c.CloseHandle(handle);
            if (release) |handle| _ = c.CloseHandle(handle);
            _ = c.CloseHandle(entered);
        }
    }
    release = c.CreateEventW(null, 1, 0, null) orelse return error.ReadinessReleaseEventCreationFailed;
    finished = c.CreateEventW(null, 1, 0, null) orelse return error.ReadinessFinishedEventCreationFailed;

    readiness_test_entered = entered;
    readiness_test_release = release;
    readiness_test_finished = finished;
    handles_published = true;
    worker_may_run = true;
    initWith(ReadinessGatedStartup);
    try std.testing.expectEqual(
        c.WAIT_OBJECT_0,
        c.WaitForSingleObject(entered, readiness_test_timeout_ms),
    );
    try std.testing.expect(!isReady());
    if (c.SetEvent(release) == 0) return error.ReadinessReleaseFailed;
    try std.testing.expectEqual(
        c.WAIT_OBJECT_0,
        c.WaitForSingleObject(finished, readiness_test_timeout_ms),
    );

    const deadline = std.time.nanoTimestamp() + 2_000_000_000;
    while (!isReady()) {
        if (std.time.nanoTimestamp() >= deadline) return error.ReadinessNativeStartupTimedOut;
        std.Thread.sleep(1_000_000);
    }
    try std.testing.expect(isReady());
}
