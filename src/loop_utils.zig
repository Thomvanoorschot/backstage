const xev = @import("xev");
const Loop = xev.Loop;
const Completion = xev.Completion;

pub fn cancelCompletion(loop: *Loop, completion: *Completion) void {
    var cancel_completion: xev.Completion = .{
        .op = .{
            .cancel = .{
                .c = completion,
            },
        },
    };
    loop.add(&cancel_completion);
}
