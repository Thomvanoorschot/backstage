const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const MethodCall = backstage.MethodCall;
const ImportedVariableActor = @import("../imported_variable.zig").ImportedVariableActor;
const FirstExportedVariable = @import("../discared_variable.zig").FirstExportedVariable;
const dv = @import("../discared_variable.zig");

pub const ImportedVariableActorProxy = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    underlying: *ImportedVariableActor,
    
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        const underlying = try ImportedVariableActor.init(ctx, allocator);
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
            first: FirstExportedVariable,
            second: dv.SecondExportedVariable,
        }, std.heap.page_allocator, params_json, .{});
        defer params.deinit();
        try self.underlying.handleImportedVariable(params.value.first, params.value.second);
    }

    const method_table = [_]MethodFn{
        methodWrapper0,
    };

    pub fn handleImportedVariable(self: *Self, first: FirstExportedVariable, second: dv.SecondExportedVariable) !void {
        var params_json = std.ArrayList(u8).init(self.allocator);
        defer params_json.deinit();
        try std.json.stringify(.{.first = first, .second = second}, .{}, params_json.writer());
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
