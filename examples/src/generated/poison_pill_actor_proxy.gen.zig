const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const MethodCall = backstage.MethodCall;
const PoisonPillActor = @import("../poison_pill.zig").PoisonPillActor;

pub const PoisonPillActorProxy = struct {
    pub const is_proxy = true;
    ctx: *Context,
    allocator: std.mem.Allocator,
    underlying: *PoisonPillActor,
    
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        const underlying = try PoisonPillActor.init(ctx, allocator);
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
    const MethodFn = *const fn (*Self, []const u8) anyerror!void;

    fn methodWrapper0(self: *Self, params_json: []const u8) !void {
        _ = params_json;
        try self.underlying.swallowPoisonPill();
    }

    const method_table = [_]MethodFn{
        methodWrapper0,
    };

    pub fn swallowPoisonPill(self: *Self) !void {
        const params_str = "";
        const method_call = MethodCall{
            .method_id = 0,
            .params = params_str,
        };
        try self.ctx.dispatchMethodCall(self.ctx.actor_id, method_call);    }

    pub fn dispatchMethod(self: *Self, method_call: MethodCall) !void {
        if (method_call.method_id >= 1) {
            return error.UnknownMethod;
        }
        try method_table[method_call.method_id](self, method_call.params);
    }
};
