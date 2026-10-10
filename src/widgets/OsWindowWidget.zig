//! Spawn a new OS Window
//!
//! If not supported by the backend, a `dvui.FloatingWindowWidget` will be used as fallback.
//!
//! This is not technically a widget (it doesn't conform to the interface) but is
//! essentially a wrapping container around a heap allocated backend/dvui.Window, or around a FloatingWindowWidget in the fallback case.
//!
//! See `dvui.osWindow`

const OsWindowWidget = @This();

inner: if (Backend.support_child_os_wins)
    union(enum) { os: *ChildOsWindow, floating: *FloatingWindowWidget }
else
    *FloatingWindowWidget,

/// Allow maximum that much OS windows.
///
/// This prevent a small code error to turn into a Window Fork Bomb as it happend to
///  me a few times while developping the feature.
///
/// If you have a legit use case for more windows, you can change this.
///  See https://github.com/david-vanderson/dvui/issues/883
pub var max_os_windows: u32 = 5;

var os_window_count: u32 = 0;

/// Thin wrapper allowing to heap allocate a new os window.
pub const ChildOsWindow = struct {
    backend: *dvui.backend,
    dvui_win: *dvui.Window,
    end_micros: ?u32 = null,

    // debug : allows to detect duplicate window
    has_begin: bool = false,

    pub fn deinit(self: ChildOsWindow, alloc: std.mem.Allocator) void {
        // The window first: it gives its textures (font atlases among them) back to its backend.
        self.dvui_win.deinit();
        self.backend.deinit();
        alloc.destroy(self.backend);
        alloc.destroy(self.dvui_win);
        os_window_count -= 1;
    }
};

/// User options for a new os window. See `dvui.osWindow`
///
/// Note that each backend is free to maintain some global state and
/// is responsible to interpret these options and the resulting effect may vary.
///
/// Fields that are left to `null` will be grab from parent window where possible.
pub const InitOptions = struct {
    /// Usually displayed on the top of the window.
    title: ?[:0]const u8 = null,
    /// content of a PNG image (or any other format stb_image can load)
    /// tip: use @embedFile
    icon: ?[]const u8 = null,
    /// Initial size of the os window.
    size: ?dvui.Size = null,
    /// Set the minimum size of the window
    min_size: ?dvui.Size = null,
    /// Set the maximum size of the window
    max_size: ?dvui.Size = null,

    fullscreen: bool = false,
    hidden: bool = false,
};

/// Close the child Os Window context, effectively rendering it.
pub fn deinit(self: OsWindowWidget) void {
    if (Backend.support_child_os_wins)
        switch (self.inner) {
            .os => |inner| {
                inner.end_micros = inner.dvui_win.end(.{}) catch unreachable;
            },
            .floating => |inner| inner.deinit(),
        }
    else
        self.inner.deinit();
}

// Retuns null if OS window creation failed (allow using fallback).
// TODO : check other errors path an see which ones makes sense to fallback instead of panic
pub fn osWindowImpl(src: std.builtin.SourceLocation, child_win_opts: OsWindowWidget.InitOptions, win_opts: Window.InitOptions) ?OsWindowWidget {
    const cw = dvui.currentWindow();
    const hashval = cw.data().id.extendId(src, win_opts.id_extra);
    const win_maybe = cw.child_os_wins.getOrPut(cw.gpa, hashval) catch @panic("OOM");
    const os_win: *ChildOsWindow = if (win_maybe.found_existing)
        win_maybe.value_ptr
    else new_os_win: {
        if (tooManyWindows()) {
            // Don't leave the entry or we gonna call illegal stuff in window.end()
            _ = cw.child_os_wins.remove(hashval);
            return null;
        }
        const new_backend = cw.gpa.create(dvui.backend) catch @panic("OOM");
        new_backend.* = cw.backend.impl.initWindowSecondary(child_win_opts) catch @panic("Failed to initialize new backend");

        // this is just for easy debug but would be nice to have a nudge strategy where possible.
        // But this as a whole other can of worms. Don't even know if this is possible on wayland for instance.
        _ = dvui.backend.c.SDL_SetWindowPosition(new_backend.window, 850, 150);

        const new_dvui_win = cw.gpa.create(dvui.Window) catch @panic("OOM");
        new_dvui_win.* = dvui.Window.init(src, cw.gpa, new_backend.backend(), .{
            .id_extra = win_opts.id_extra,
            .theme = win_opts.theme orelse cw.theme,
            .button_order = win_opts.button_order orelse cw.button_order,
            // Do not grab the parent's one, because closing a child window is not the same as
            // quitting the application. User should explicitly use the same open_flag for this behavior.
            .open_flag = win_opts.open_flag,
        }) catch
            @panic("Failed to initialize new dvui.Window");
        new_dvui_win.is_primary = false;
        win_maybe.value_ptr.* = .{ .backend = new_backend, .dvui_win = new_dvui_win };
        break :new_os_win win_maybe.value_ptr;
    };
    std.debug.assert(os_win.dvui_win.data().id == hashval);
    os_win.dvui_win.begin(cw.frame_time_ns) catch |err| {
        dvui.logError(@src(), err, "Something wrong in child's dvui.Window.begin()", .{});
    };
    if (os_win.has_begin) {
        dvui.log.err("duplicate os Window. id {f} (highlighted in red); you may need to pass .{{.id_extra=<loop index>}} as widget options (see https://github.com/david-vanderson/dvui/blob/master/readme-implementation.md#widget-ids )", .{hashval});
        dvui.Debug.errorOutline(os_win.dvui_win.rectScale().r);
    }
    os_win.has_begin = true;
    return .{ .inner = .{ .os = os_win } };
}

pub fn osWindowFallback(src: std.builtin.SourceLocation, child_win_opts: OsWindowWidget.InitOptions, win_opts: Window.InitOptions) OsWindowWidget {
    // The OS window's size to begin with (centered, as a floating window places itself), its
    // least and most size, and its close button: the same `open_flag` an OS window's close sets.
    // Stepped past one already there, as an OS steps a new window past another (`.nudge`).
    const float = dvui.floatingWindow(src, .{ .open_flag = win_opts.open_flag, .window_avoid = .nudge }, .{
        .id_extra = win_opts.id_extra,
        .rect = if (child_win_opts.size) |s| .{ .w = s.w, .h = s.h } else null,
        .min_size_content = child_win_opts.min_size,
        .max_size_content = if (child_win_opts.max_size) |s| .{ .w = s.w, .h = s.h } else null,
    });
    const header = dvui.windowHeader(child_win_opts.title orelse "Dvui child window", "", win_opts.open_flag);
    float.dragAreaSet(header);
    // Closed by its close button: the next frame, which no longer draws it, comes now.
    if (win_opts.open_flag) |of| if (!of.*) dvui.refresh(null, @src(), float.data().id);
    // A backend that shows parts of the frame in OS windows of their own may show this one in one.
    dvui.currentWindow().backend.osWindowFloating(float.data().id, header, child_win_opts);
    // TODO : deal with Floating window inside the floating window.
    // something is wrong with rendering order, but maybe we want the floating win declared
    // inside an osWindow to not be able to exceed it's boundaries ? Or on the contrary it's nice
    // that they just become "sibling" floating window ?
    if (Backend.support_child_os_wins)
        return .{ .inner = .{ .floating = float } }
    else
        return .{ .inner = float };
}

// See `max_os_windows`
fn tooManyWindows() bool {
    if (os_window_count < max_os_windows) {
        os_window_count += 1;
        return false;
    }
    if (builtin.mode == .Debug) {
        dvui.log.warn(
            \\Won't open more than {} OS window. Falling back to FloatingWindow.
            \\  This safety prevents windows fork bombs while hacking on multi os windows. 
            \\  You can change the allowed max with `dvui.OsWindowWidget.max_os_windows = X`;
        , .{max_os_windows});
    } else {
        dvui.log.info("Cannot spawn more than {} OS windows. Falling back to floating window", .{max_os_windows});
    }
    return true;
}

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("../dvui.zig");

const Backend = dvui.Backend;
const Window = dvui.Window;
const FloatingWindowWidget = dvui.FloatingWindowWidget;
