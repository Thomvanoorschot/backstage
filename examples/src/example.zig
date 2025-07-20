const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;
const LazyActor = @import("lazy_actor.zig").LazyActor;
const LazyActorProxy = @import("generated/lazy_actor_proxy.gen.zig").LazyActorProxy;
const ActorID = backstage.ActorID;

test "Ultra-fast method dispatch" {
    var engine = try backstage.Engine.init(testing.allocator);
    defer engine.deinit();

    // Spawn actor
    const proxy = try engine.spawnActor(LazyActorProxy, .{ .id = try ActorID.initOwned(testing.allocator, "LazyActor", "test_actor") });
    // This call becomes:
    // 1. Serialize params (JSON)
    // 2. Create MethodCall with method_id = 0
    // 3. Send message
    // 4. Actor receives -> LazyActorMethodTable[0](actor, params)
    // 5. Direct call to LazyActorWrapper0 -> actor.addAmount()
    try proxy.addAmount(LazyActor.AddAmountRequest{ .amount = 42 });

    try engine.loop.run(.once);
    try testing.expect(proxy.amount == 42);
}
