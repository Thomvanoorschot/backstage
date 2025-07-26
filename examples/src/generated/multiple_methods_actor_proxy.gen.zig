const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const MethodCall = backstage.MethodCall;
const MultipleMethodsActor = @import("../multiple_methods.zig").MultipleMethodsActor;
const AddAmountWithMultiplier = @import("../multiple_methods.zig").AddAmountWithMultiplier;

pub const MultipleMethodsActorProxy = struct {
    pub const is_proxy = true;
    ctx: *Context,
    allocator: std.mem.Allocator,
    underlying: *MultipleMethodsActor,
    
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        const underlying = try MultipleMethodsActor.init(ctx, allocator);
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
    inline fn methodWrapper0(self: *Self, params_json: []const u8) !void {
        const params = try std.json.parseFromSlice(struct {
            amount: u64,
        }, std.heap.page_allocator, params_json, .{});
        defer params.deinit();
        return self.underlying.addAmount(params.value.amount);
    }

    inline fn methodWrapper1(self: *Self, params_json: []const u8) !void {
        const params = try std.json.parseFromSlice(struct {
            params: AddAmountWithMultiplier,
        }, std.heap.page_allocator, params_json, .{});
        defer params.deinit();
        return self.underlying.addAmountWithMultiplier(params.value.params);
    }

    pub inline fn addAmount(self: *Self, amount: u64) !void {
        var params_json = std.ArrayList(u8).init(self.allocator);
        defer params_json.deinit();
        try std.json.stringify(.{.amount = amount}, .{}, params_json.writer());
        const params_str = try params_json.toOwnedSlice();
        defer self.allocator.free(params_str);
        const method_call = MethodCall{
            .method_id = 0,
            .params = params_str,
        };
        return self.ctx.dispatchMethodCall(self.ctx.actor_id, method_call);    }

    pub inline fn addAmountWithMultiplier(self: *Self, params: AddAmountWithMultiplier) !void {
        var params_json = std.ArrayList(u8).init(self.allocator);
        defer params_json.deinit();
        try std.json.stringify(.{.params = params}, .{}, params_json.writer());
        const params_str = try params_json.toOwnedSlice();
        defer self.allocator.free(params_str);
        const method_call = MethodCall{
            .method_id = 1,
            .params = params_str,
        };
        return self.ctx.dispatchMethodCall(self.ctx.actor_id, method_call);    }

    pub inline fn dispatchMethod(self: *Self, method_call: MethodCall) !void {
        return switch (method_call.method_id) {            0 => methodWrapper0(self, method_call.params),
            1 => methodWrapper1(self, method_call.params),
            else => error.UnknownMethod,
        };
    }
};
