const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const MethodCall = backstage.MethodCall;
const DiscaredVariableActor = @import("../discared_variable.zig").DiscaredVariableActor;

pub const DiscaredVariableActorProxy = struct {
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
    const MethodFn = *const fn (*Self, []const u8) anyerror!void;

    fn methodWrapper0(self: *Self, params_json: []const u8) !void {
        const params = try std.json.parseFromSlice(struct {
            unused_param1: []const u8,
            unused_param2: u64,
            used_param: u64,
        }, std.heap.page_allocator, params_json, .{});
        defer params.deinit();
        try self.underlying.handleDiscaredVariable(params.value.unused_param1, params.value.unused_param2, params.value.used_param);
    }

    const method_table = [_]MethodFn{
        methodWrapper0,
    };

    pub fn handleDiscaredVariable(self: *Self, unused_param1: []const u8, unused_param2: u64, used_param: u64) !void {
        var params_json = std.ArrayList(u8).init(self.allocator);
        defer params_json.deinit();
        try std.json.stringify(.{.unused_param1 = unused_param1, .unused_param2 = unused_param2, .used_param = used_param}, .{}, params_json.writer());
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
