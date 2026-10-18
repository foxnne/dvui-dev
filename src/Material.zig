//! What the app's windows are made of: an opaque window (`none`, the default), or one that shows
//! what is behind it — through clear window colour (`transparent`), blurred (`blur`), frosted
//! (`frost`), or as Liquid Glass (`liquid`). One for the app (`dvui.materialSet`): every OS window
//! a backend shows takes it, and glass drawn in the app follows it, so they look as one.
//!
//! A backend offers the kinds it can show (`Backend.materialKinds`), and a kind asked for and not
//! offered falls back to the best one below it that is (`dvui.materialEffective`).

const Material = @This();

kind: Kind = .none,
/// How much of the theme's window colour covers what is behind, 0 (clear) to 1. Ignored by
/// `none`; `transparent` at 1 looks as `none` does.
opacity: f32 = 1,

/// From the plainest to the richest: what `dvui.materialEffective` falls back through.
pub const Kind = enum { none, transparent, blur, frost, liquid };

/// The kinds a backend offers. A backend offers a kind only if every surface it puts glass on can
/// show it: a backend whose OS windows can only frost offers no `liquid`, so glass drawn in the app
/// frosts too and the look stays one.
pub const Kinds = packed struct {
    none: bool = true,
    transparent: bool = false,
    blur: bool = false,
    frost: bool = false,
    liquid: bool = false,

    pub fn has(self: Kinds, kind: Kind) bool {
        return switch (kind) {
            inline else => |k| @field(self, @tagName(k)),
        };
    }
};

/// `kind`, or the best kind below it in `offered`: `none` at the least.
pub fn effective(self: Material, offered: Kinds) Material {
    var k = @backingInt(self.kind);
    while (k > 0) : (k -= 1) {
        if (offered.has(@fromBackingInt(@intCast(k)))) return .{ .kind = @fromBackingInt(@intCast(k)), .opacity = self.opacity };
    }
    return .{ .kind = .none, .opacity = self.opacity };
}

test effective {
    const std = @import("std");
    const mac_old: Kinds = .{ .transparent = true, .blur = true, .frost = true };
    try std.testing.expectEqual(Kind.frost, (Material{ .kind = .liquid }).effective(mac_old).kind);
    try std.testing.expectEqual(Kind.blur, (Material{ .kind = .blur }).effective(mac_old).kind);
    const windows: Kinds = .{ .transparent = true, .frost = true };
    try std.testing.expectEqual(Kind.transparent, (Material{ .kind = .blur }).effective(windows).kind);
    try std.testing.expectEqual(Kind.none, (Material{ .kind = .liquid }).effective(.{}).kind);
    try std.testing.expectEqual(@as(f32, 0.4), (Material{ .kind = .liquid, .opacity = 0.4 }).effective(windows).opacity);
}
