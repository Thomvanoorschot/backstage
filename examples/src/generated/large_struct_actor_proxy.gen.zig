const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const MethodCall = backstage.MethodCall;
const zborParse = backstage.zborParse;
const zborStringify = backstage.zborStringify;
const zborDataItem = backstage.zborDataItem;
const LargeStructActor = @import("../large_struct.zig").LargeStructActor;
const LargeStruct = @import("../large_struct.zig").LargeStruct;

pub const LargeStructActorProxy = struct {
    pub const is_proxy = true;
    ctx: *Context,
    allocator: std.mem.Allocator,
    underlying: *LargeStructActor,
    
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        const underlying = try LargeStructActor.init(ctx, allocator);
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
        const result = try zborParse(LargeStruct, try zborDataItem.new(params), .{ .allocator = self.allocator });
        return self.underlying.handleLargeStruct(result);
    }

    pub inline fn handleLargeStruct(self: *Self, ls: LargeStruct) !void {
        var params_str = std.ArrayList(u8).init(self.allocator);
        defer params_str.deinit();
        try zborStringify(ls, .{}, params_str.writer());
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
