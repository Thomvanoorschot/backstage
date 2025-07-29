const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const MethodCall = backstage.MethodCall;
const zborParse = backstage.zborParse;
const zborStringify = backstage.zborStringify;
const zborDataItem = backstage.zborDataItem;
const DiscaredVariableActor = @import("../discared_variable.zig").DiscaredVariableActor;

pub const DiscaredVariableActorProxy = struct {
    pub const is_proxy = true;
    ctx: *Context,
    allocator: std.mem.Allocator,
    underlying: *DiscaredVariableActor,
    
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        const underlying = try DiscaredVariableActor.init(ctx, allocator);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
            .underlying = underlying,
        };
        return self;
    }

    pub fn deinit(self: *Self) !void {
        try self.underlying.deinit();
        self.allocator.destroy(self);
    }
    inline fn methodWrapper0(self: *Self, params: []const u8) !void {
        const result = try zborParse(struct {
            unused_param1: []const u8,
            unused_param2: u64,
            used_param: u64,
        }, try zborDataItem.new(params), .{ .allocator = self.allocator });
        return self.underlying.handleDiscaredVariable(result.unused_param1, result.unused_param2, result.used_param);
    }

    pub inline fn handleDiscaredVariable(self: *Self, unused_param1: []const u8, unused_param2: u64, used_param: u64) !void {
        var params_str = std.ArrayList(u8).init(self.allocator);
        defer params_str.deinit();
        try zborStringify(.{.unused_param1 = unused_param1, .unused_param2 = unused_param2, .used_param = used_param}, .{}, params_str.writer());
        const method_call = MethodCall{
            .method_id = 0,
            .params = params_str.items,
        };
        return self.ctx.dispatchMethodCall(self.ctx.actor_id, method_call);    }

    pub inline fn dispatchMethod(self: *Self, method_call: MethodCall) !void {
        return switch (method_call.method_id) {            0 => methodWrapper0(self, method_call.params),
            else => error.UnknownMethod,
        };
    }
};
