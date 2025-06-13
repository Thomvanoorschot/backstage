const std = @import("std");
const backstage = @import("backstage");
const brkr_impl = @import("broker_impl.zig");
const brkr_actr = @import("broker_actor.zig");
const conn_actr = @import("../http/connection_actor.zig");
const shared_models = @import("shared_models");
const date_utils = @import("../utils/date_utils.zig");

const OHLCActorMessage = shared_models.OHLCActor;
const OHLCList = shared_models.OHLCList;
const BrokerActorMessage = shared_models.BrokerActor;
const OHLCUpdate = shared_models.OHLCUpdate;
const OHLC = shared_models.OHLC;
const ConnectionActorMessage = shared_models.ConnectionActor;

const xev = backstage.xev;
const ActorInterface = backstage.ActorInterface;
const Allocator = std.mem.Allocator;
const Context = backstage.Context;
const BrokerType = brkr_impl.BrokerType;
const BrokerActor = brkr_actr.BrokerActor;
const Envelope = backstage.Envelope;
const ManagedString = shared_models.ManagedString;

pub const OHLCActor = struct {
    allocator: Allocator,
    arena_state: std.heap.ArenaAllocator,
    ctx: *Context,
    ohlc_list: OHLCList,
    notify_subscribers_completion: xev.Completion = undefined,
    last_timestamp: ?u64 = null, // Track the last timestamp we processed
    const Self = @This();

    pub fn init(ctx: *Context, allocator: Allocator) !*Self {
        const self = try allocator.create(Self);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();

        self.* = .{
            .allocator = allocator,
            .arena_state = arena_state,
            .ctx = ctx,
            .ohlc_list = OHLCList.init(allocator),
            .last_timestamp = null,
        };
        return self;
    }

    pub fn deinit(self: *Self) !void {
        self.arena_state.deinit();
        try self.ctx.shutdown();
    }

    pub fn receive(self: *Self, envelope: Envelope) !void {
        const ohlc_msg: OHLCActorMessage = try OHLCActorMessage.decode(envelope.message, self.allocator);
        if (ohlc_msg.message == null) {
            return error.InvalidMessage;
        }
        switch (ohlc_msg.message.?) {
            .start => |m| {
                self.ohlc_list.ticker = m.ticker;
                self.last_timestamp = null; // Reset timestamp tracking on start

                try self.ctx.send("kraken_broker_actor", BrokerActorMessage{
                    .message = .{
                        .subscribe = .{
                            .ticker = m.ticker,
                            .market_data = .OHLC,
                        },
                    },
                });

                try self.ctx.subscribeToActorTopic("kraken_broker_actor", "ohlc_updates");
                try self.ctx.runContinuously(
                    Self,
                    notify_subscribers,
                    &self.notify_subscribers_completion,
                    self,
                    20,
                );
            },
            .update => |m| {
                const timestamp_unix = try date_utils.DateTime.parse(m.timestamp.Owned.str, .rfc3339);
                const current_timestamp = @as(u64, @intCast(timestamp_unix.unix(.seconds)));

                // Only process if this is a new second
                if (self.last_timestamp == null or current_timestamp > self.last_timestamp.?) {
                    const ohlc = OHLC{
                        .ticker = m.ticker,
                        .open = m.open,
                        .high = m.high,
                        .low = m.low,
                        .close = m.close,
                        .trades = m.trades,
                        .volume = m.volume,
                        .interval = m.interval,
                        .timestamp = m.timestamp,
                        .timestamp_unix = current_timestamp,
                    };

                    // Update the last candle if it's from the same second, otherwise append
                    if (self.ohlc_list.ohlc.getLastOrNull()) |last| {
                        if (last.timestamp_unix == current_timestamp) {
                            _ = self.ohlc_list.ohlc.pop();
                            try self.ohlc_list.ohlc.append(ohlc);
                        } else {
                            try self.ohlc_list.ohlc.append(ohlc);
                        }
                    } else {
                        try self.ohlc_list.ohlc.append(ohlc);
                    }

                    self.last_timestamp = current_timestamp;
                }
                m.deinit();
            },
        }
    }

    fn notify_subscribers(self: *Self) !void {
        const ohlc_update_msg = ConnectionActorMessage{ .message = .{
            .ohlc_update = self.ohlc_list,
        } };
        const ohlc_update_msg_bytes = try ohlc_update_msg.encode(self.allocator);
        defer self.allocator.free(ohlc_update_msg_bytes);
        try self.ctx.publish(ohlc_update_msg_bytes);
    }
};
