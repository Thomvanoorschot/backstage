const std = @import("std");
const act = @import("actor.zig");
const type_utils = @import("type_utils.zig");
const actr_id = @import("actor_id.zig");

const ActorInterface = act.ActorInterface;
const ActorHashMap = actr_id.ActorHashMap;
const ActorID = actr_id.ActorID;

pub const Registry = struct {
    actorsByID: ActorHashMap(*ActorInterface),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .actorsByID = ActorHashMap(*ActorInterface).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.actorsIDMap.deinit();
    }

    pub fn remove(self: *Registry, id: ActorID) bool {
        return self.actorsByID.remove(id);
    }

    pub fn fetchRemove(self: *Registry, id: ActorID) ?*ActorInterface {
        const keyval = self.actorsByID.fetchRemove(id);
        if (keyval) |kv| {
            return kv.value;
        }
        return null;
    }

    pub fn getByID(self: *Registry, id: ActorID) ?*ActorInterface {
        return self.actorsByID.get(id);
    }

    pub fn add(self: *Registry, id: ActorID, actor: *ActorInterface) !void {
        try self.actorsByID.put(id, actor);
    }
};
