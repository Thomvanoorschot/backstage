const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const ImportedVariableActorProxy = @import("generated/imported_variable_actor_proxy.gen.zig").ImportedVariableActorProxy;
const FirstExportedVariable = @import("discared_variable.zig").FirstExportedVariable;
const dv = @import("discared_variable.zig");

// @generate-proxy
pub const ImportedVariableActor = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
        };
        return self;
    }

    pub fn handleImportedVariable(_: *Self, first: FirstExportedVariable, second: dv.SecondExportedVariable) !void {
        std.log.info("parameters from imported file: {d}, {d}", .{ first.number, second.number });
    }

    pub fn deinit(_: *Self) !void {}
};

test "Imported variable" {
    testing.log_level = .info;
    var engine = try backstage.Engine.init(std.testing.allocator);
    defer engine.deinit();

    const test_actor = try engine.getActor(ImportedVariableActorProxy, "test_actor");
    try test_actor.handleImportedVariable(.{ .number = 1 }, .{ .number = 42 });
    try engine.loop.run(.once);
}
