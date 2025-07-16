const engn = @import("engine.zig");
const actr_id = @import("actor_id.zig");
const type_utils = @import("type_utils.zig");

const unsafeAnyOpaqueCast = type_utils.unsafeAnyOpaqueCast;
const Engine = engn.Engine;
const ActorID = actr_id.ActorID;

pub const ActorFactory = struct {
    engine: *Engine,

    pub fn init(engine: *Engine) ActorFactory {
        return .{
            .engine = engine,
        };
    }

    pub fn getActor(self: *ActorFactory, comptime ActorType: type, key: []const u8) !*ActorType {
        const actor_id = ActorID.init(@typeName(ActorType), key);

        if (self.engine.registry.getByID(actor_id)) |actor| {
            return unsafeAnyOpaqueCast(ActorType, actor.impl);
        }

        return self.engine.spawnActor(ActorType, .{
            .id = key,
            .capacity = 1024,
        });
    }
};
