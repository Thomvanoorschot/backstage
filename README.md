# Backstage: Actor Framework for Zig

Backstage is a high-performance, event-driven actor framework for the Zig programming language. Built on top of [libxev](https://github.com/mitchellh/libxev), it provides a robust foundation for building concurrent applications using the actor model pattern.

The main goal of this project is to gain deeper understanding of the programming language while building something practical and useful. By implementing an actor framework from scratch, this project explores:

- **Event-Driven Architecture**: Built on libxev for high-performance, non-blocking I/O operations
- **Actor Lifecycle Management**: Automated actor supervision with parent-child relationships
- **Memory Efficient**: Careful memory management with configurable inbox capacities
- **Actor Registry**: Built-in registry for actor discovery and management
- **Topic-based Messaging**: Publish/subscribe pattern with named topics for decoupled communication
- **Concurrent programming patterns**: Built to be run on a single core yet handle concurrent workloads

## Architecture

The framework consists of several core components:

- **Engine**: The central runtime that manages the event loop and actor lifecycle
- **ActorInterface**: Type-erased interface for actor communication and management
- **Context**: Provides actors with access to the engine and manages parent-child relationships
- **Registry**: Maps actor IDs and message types to actor instances
- **Inbox**: Thread-safe message queue with configurable capacity
- **Envelope**: Message wrapper that includes sender information and message types for routing
- **Topic Subscriptions**: Decoupled publish/subscribe messaging system

## Installation

Add Backstage to your `build.zig.zon`:

```zig
.dependencies = .{
    .backstage = .{
        .url = "https://github.com/Thomvanoorschot/backstage/archive/main.tar.gz",
        .hash = "...", // Update with actual hash
    },
},
```

Or use zig fetch:

```bash
zig fetch --save https://github.com/Thomvanoorschot/backstage/archive/main.tar.gz
```

## Quick Start

```zig
const std = @import("std");
const backstage = @import("backstage");
const Envelope = backstage.Envelope;

// Define your actor
const MyActor = struct {
    ctx: *backstage.Context,
    allocator: std.mem.Allocator,

    const Self = @This();
    pub fn init(ctx: *backstage.Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
        };
        return self;
    }

    pub fn receive(self: *Self(), envelope: Envelope) !void {
        defer envelope.deinit(self.allocator);
        // This example shows zig-protobuf encoded payloads, any encoding (or none at all) would work
        const actor_msg: MyActorMessage = try MyActorMessage.decode(message.payload, self.allocator);
        if (actor_msg.message == null) {
            return error.InvalidMessage;
        }
        switch (actor_msg.message.?) {
            .init => |m| {
                std.log.info("Received message {}", .{m.example});
            }
        }
    }

    pub fn deinit(self: *Self) !void {
        try self.ctx.shutdown();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the engine
    var engine = try backstage.Engine.init(allocator);
    defer engine.deinit();

    // Spawn actors
    const publisher = try engine.spawnActor(MyActor, .{
        .id = "publisher",
        .capacity = 1024,
    });

    const subscriber = try engine.spawnActor(MyActor, .{
        .id = "subscriber",
        .capacity = 1024,
    });

    // Subscribe to the publisher's default topic
    try subscriber.ctx.subscribeToActor("publisher");

    // Or subscribe to a specific topic
    try subscriber.ctx.subscribeToActorTopic("publisher", "news");

    // Publish messages
    // Normaly you would probably send some more complex encoded struct, it is able 
    // to handle structs that have a method with the following signature:
    // pub fn encode(self: Self, allocator: Allocator) anyerror![]u8
    try publisher.ctx.publish("Hello, subscribers!");
    try publisher.ctx.publishToTopic("news", "Breaking news!");
    try publisher.ctx.publishToTopic("news", MyActorMessage{
        .message = .{ .input = "Hello, World!" },
    });

    // Send direct messages
    try engine.send(null, "subscriber", "Direct message");
    try engine.send(null, "subscriber", MyActorMessage{
        .message = .{ .input = "Hello, World!" },
    });
    // Run the event loop
    try engine.run();
}
```

### Publishing Messages

```zig
// Publish to the default topic
try actor.ctx.publish("Hello, world!");

// Publish to a specific topic
try actor.ctx.publishToTopic("events", "Something happened!");
```

### Subscribing to Topics

```zig
// Subscribe to an actor's default topic
try subscriber.ctx.subscribeToActor("publisher-id");

// Subscribe to a specific topic from an actor
try subscriber.ctx.subscribeToActorTopic("publisher-id", "events");

// Unsubscribe from topics
try subscriber.ctx.unsubscribeFromActor("publisher-id");
try subscriber.ctx.unsubscribeFromActorTopic("publisher-id", "events");
```

### Message Handling

Actors receive both direct messages and published messages through the same `receive` method, differentiated by the `message_type` field in the envelope. You could add some logic based on this, but you don't have to:

```zig
pub fn receive(self: *Self, envelope: Envelope) !void {
    switch (envelope.message_type) {
        .send => {
            // Handle direct point-to-point messages
        },
        .publish => {
            // Handle messages from subscribed topics
        },
        else => {},
    }
}
```

## Examples

For comprehensive examples and real-world usage, see the [Zigma algorithmic trading framework](https://github.com/Thomvanoorschot/zigma), which demonstrates advanced patterns.

## API Reference

### Engine

The `Engine` is the central component that manages the actor system:

- `init(allocator)` - Initialize a new engine instance
- `spawnActor(ActorType, options)` - Create and register a new actor
- `send(sender, id, message_type, message)` - Send a message to a specific actor by ID
- `run()` - Start the event loop
- `deinit()` - Clean up resources

### Context

The `Context` provides actors with communication and lifecycle management capabilities:

#### Direct Messaging
- `send(target_id, message)` - Send a direct message to another actor

#### Topic-based Messaging
- `publish(message)` - Publish a message to the default topic
- `publishToTopic(topic, message)` - Publish a message to a specific topic
- `subscribeToActor(target_id)` - Subscribe to another actor's default topic
- `subscribeToActorTopic(target_id, topic)` - Subscribe to a specific topic from another actor
- `unsubscribeFromActor(target_id)` - Unsubscribe from another actor's default topic
- `unsubscribeFromActorTopic(target_id, topic)` - Unsubscribe from a specific topic

#### Actor Management
- `spawnActor(ActorType, options)` - Spawn a new actor
- `spawnChildActor(ActorType, options)` - Spawn a child actor with supervision
- `shutdown()` - Clean shutdown with automatic subscription cleanup

### Actor Interface

Actors must implement:

- `init(ctx, allocator)` - Actor initialization
- `receive(envelope)` - Message handling for both direct and published messages
- `deinit()` - Optional cleanup (automatically detected)

### Envelope

Message wrapper containing:

- `sender_id` - ID of the sending actor (optional)
- `message_type` - Type of message (send, publish, subscribe, unsubscribe)
- `message` - The actual message payload

## Design Principles

- **Isolation**: Actors maintain their own state and communicate only through messages
- **Decoupling**: Topic-based messaging allows loose coupling between actors
- **Supervision**: Parent actors manage child actor lifecycles
- **Performance**: Zero-allocation message passing in steady state
- **Type Safety**: Compile-time message type checking
- **Resource Management**: Automatic cleanup of actor hierarchies and subscriptions

## Current Status

This is an early-stage implementation, focusing on core actor framework concepts with topic-based messaging. The project is primarily meant as a learning exercise and may evolve significantly as understanding of both the language and actor patterns deepens.

## Upcoming features

- **Supervision tree**: Adding the ability to create a supervision tree with strategies
- **Inbox back pressure**: Making the send be blocking as long as the receiver inbox is full
- **Dead letter queue**: Undeliverable messages should end up in the DeadLetter queue
- **Inspector**: A way for the user to inspect the current state of the actor system

## License

MIT License - see LICENSE file for details.