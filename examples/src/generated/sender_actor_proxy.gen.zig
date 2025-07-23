const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const MethodCall = backstage.MethodCall;
const SenderActor = @import("../actor_to_actor.zig").SenderActor;

pub const SenderActorProxy = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    underlying: *SenderActor,
    
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        const underlying = try SenderActor.init(ctx, allocator);
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
        const params = try std.json.parseFromSlice(struct {
            message: []const u8,
        }, std.heap.page_allocator, params_json, .{});
        defer params.deinit();
        try self.underlying.sendMessage(params.value.message);
    }

    const method_table = [_]MethodFn{
        methodWrapper0,
    };

    pub fn sendMessage(self: *Self, message: []const u8) !void {
        var params_json = std.ArrayList(u8).init(self.allocator);
        defer params_json.deinit();
        try std.json.stringify(.{.message = message}, .{}, params_json.writer());
        const params_str = try params_json.toOwnedSlice();
        defer self.allocator.free(params_str);
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
