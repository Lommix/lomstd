const std = @import("std");
const assert = std.debug.assert;

pub const StateMask = std.bit_set.IntegerBitSet(64);

/// Max per-goal runtime payload size. `rage.Brain.registerSet` asserts each
/// set's `goal_ctx_size` / `goal_ctx_align` fits within these bounds.
pub const GOAL_CTX_MAX: usize = 128;
pub const GOAL_CTX_ALIGN: usize = 8;

pub fn MaskFromEnum(comptime val: anytype) StateMask {
    var mask = StateMask.initEmpty();
    mask.set(@intFromEnum(val));
    return mask;
}

pub const Agent = struct {
    pub const State = enum { startup, running, failed };
    world: StateMask = .initEmpty(),
    elapsed: f32 = 0,
    step: u32 = 0,
    plan: ?Plan = null,
    failed_goals: StateMask = .initEmpty(),
    current_state: State = .startup,
    current_action: ?Action = null,
    current_goal: ?Goal = null,
    /// Global goal id most recently completed. Used by default scorer to
    /// penalize immediate repeats across sets (fairness bias).
    last_goal: ?u32 = null,
    goal_ctx_buf: [GOAL_CTX_MAX]u8 align(GOAL_CTX_ALIGN) = @splat(0),

    pub fn goalCtxAs(self: *Agent, comptime T: type) *T {
        return @ptrCast(@alignCast(&self.goal_ctx_buf));
    }

    pub fn setGoal(self: *Agent, val: anytype) void {
        const T = @TypeOf(val);
        if (T == void) return;
        const p: *T = @ptrCast(@alignCast(&self.goal_ctx_buf));
        p.* = val;
    }

    pub fn finishAction(self: *Agent) void {
        if (self.current_action) |a| {
            self.world = a.finish(self.world);
            self.current_action = null;
        }
    }

    pub fn setFailed(self: *Agent) void {
        self.current_state = .failed;
    }

    pub fn resetForNewGoal(self: *Agent) void {
        self.failed_goals = .initEmpty();
        self.current_action = null;
        self.current_goal = null;
        self.plan = null;
        self.step = 0;
    }

    pub fn transitionToRunning(self: *Agent) void {
        assert(self.current_state == .startup);
        self.current_state = .running;
    }

    pub fn setState(self: *Agent, enum_val: anytype, state: bool) void {
        const index = @intFromEnum(enum_val);
        if (state) self.world.set(index) else self.world.unset(index);
    }

    pub fn isStateSet(self: *const Agent, enum_val: anytype) bool {
        const index = @intFromEnum(enum_val);
        return self.world.isSet(index);
    }

    pub fn setStateOffset(self: *Agent, enum_val: anytype, offset: u32, state: bool) void {
        const index = @intFromEnum(enum_val) + offset;
        if (state) self.world.set(index) else self.world.unset(index);
    }

    pub fn isStateSetOffset(self: *const Agent, enum_val: anytype, offset: u32) bool {
        const index = @intFromEnum(enum_val) + offset;
        return self.world.isSet(index);
    }

    pub const Context = struct {
        pub const ActionFn = *const fn (*anyopaque, *const Action) anyerror!void;
        pub const FinishFn = *const fn (*anyopaque, *const Action) anyerror!bool;

        ptr: *anyopaque,
        on_startup: ActionFn,
        on_finished: ?ActionFn = null,
        on_fail: ?ActionFn = null,
        is_finished: FinishFn,
    };

    pub fn tick(
        self: *Agent,
        dt: f32,
        ctx: Context,
    ) !void {
        self.elapsed += dt;

        if (self.current_action) |*action| {
            switch (self.current_state) {
                .startup => {
                    ctx.on_startup(ctx.ptr, action) catch {
                        self.setFailed();
                        return;
                    };

                    if (self.current_state == .startup) self.current_state = .running;
                },
                .running => {
                    const completed = ctx.is_finished(ctx.ptr, action) catch {
                        self.setFailed();
                        return;
                    };

                    if (completed) self.finishAction();
                },
                .failed => {
                    // this should run only once, freeze agent on fail!
                    if (ctx.on_fail) |fail_fn| try fail_fn(ctx.ptr, action);

                    if (self.current_goal) |goal| {
                        self.failed_goals.set(goal.ty);
                        self.world = goal.applyClear(self.world);
                    }

                    // cleanup for new goal
                    self.plan = null;
                    self.current_goal = null;
                    self.current_action = null;
                },
            }
        } else {
            const plan = self.plan orelse return;
            const next_action = plan.step(self.step) orelse {
                // goal finished
                if (self.current_goal) |goal| {
                    self.world = goal.applyClear(self.world);
                    self.last_goal = goal.ty;
                }

                self.resetForNewGoal();
                return;
            };
            self.current_action = next_action;
            self.current_state = .startup;
            self.step += 1;
            self.elapsed = 0;
            return;
        }
    }

    pub fn fmt(self: *const Agent, w: *std.Io.Writer) !void {
        try w.print("state: {b}\n", .{self.world.mask});
        try w.print("fail:  {b}\n", .{self.failed_goals.mask});
        try w.print("step:   {d}\n", .{self.step});

        if (self.current_action) |a| {
            try w.print("action: {d}\n", .{a.ty});
        }
    }
};

/// Set-scoped window onto an `Agent`. Passed to per-set hooks so they can
/// read/write their own local state bits without knowing the global offset
/// the set was assigned at registration.
pub const AgentSetView = struct {
    agent: *Agent,
    state_offset: u32,

    pub fn setState(self: AgentSetView, enum_val: anytype, state: bool) void {
        self.agent.setStateOffset(enum_val, self.state_offset, state);
    }

    pub fn isStateSet(self: AgentSetView, enum_val: anytype) bool {
        return self.agent.isStateSetOffset(enum_val, self.state_offset);
    }
};

pub const Goal = struct {
    ty: u32,
    /// the end state of the goal
    desires: StateMask = .initEmpty(),
    /// required states to start
    requires: StateMask = .initEmpty(),
    /// forbidden states
    forbids: StateMask = .initEmpty(),
    /// cleared states after goal (success & fail)
    clears: StateMask = .initEmpty(),

    pub fn applyClear(self: *const Goal, world: StateMask) StateMask {
        return world.differenceWith(self.clears);
    }

    pub fn valid(self: *const Goal, world: StateMask) bool {
        const req_met = self.requires.intersectWith(world).eql(self.requires);
        const forbig_met = self.forbids.intersectWith(world).eql(.initEmpty());
        return req_met and forbig_met;
    }
};

pub fn GoalBuilder(comptime E: type) type {
    return struct {
        const Self = @This();
        goal: Goal,

        pub fn new(any_enum: anytype) Self {
            return Self{ .goal = .{ .ty = @intFromEnum(any_enum) } };
        }

        pub fn desire(self: Self, val: E) Self {
            var s = self;
            s.goal.desires.set(@intFromEnum(val));
            return s;
        }

        pub fn forbid(self: Self, val: E) Self {
            var s = self;
            s.goal.forbids.set(@intFromEnum(val));
            return s;
        }

        pub fn require(self: Self, val: E) Self {
            var s = self;
            s.goal.requires.set(@intFromEnum(val));
            return s;
        }

        pub fn clear(self: Self, val: E) Self {
            var s = self;
            s.goal.clears.set(@intFromEnum(val));
            return s;
        }

        pub fn clearAll(self: Self, vals: []const E) Self {
            var s = self;
            for (vals) |val| s.goal.requires.set(@intFromEnum(val));
            return s;
        }
    };
}

pub const Action = struct {
    ty: u32,
    cost: f32 = 1,
    solves: StateMask = .initEmpty(),
    requires: StateMask = .initEmpty(),
    forbids: StateMask = .initEmpty(),
    clears: StateMask = .initEmpty(),

    pub fn finish(self: *const Action, world: StateMask) StateMask {
        return world.unionWith(self.solves).differenceWith(self.clears);
    }

    pub fn new(comptime ty: anytype, comptime solves: anytype, comptime requires: anytype, comptime clears: anytype) Action {
        var solve_mask = StateMask.initEmpty();
        var require_mask = StateMask.initEmpty();
        var clear_mask = StateMask.initEmpty();

        if (@typeInfo(@TypeOf(ty)) != .@"enum") @compileError("action type must be enum value");
        inline for (solves) |ebit| solve_mask.set(@intFromEnum(ebit));
        inline for (requires) |ebit| require_mask.set(@intFromEnum(ebit));
        inline for (clears) |ebit| clear_mask.set(@intFromEnum(ebit));

        return Action{
            .ty = @intFromEnum(ty),
            .solves = solve_mask,
            .requires = require_mask,
            .clears = clear_mask,
        };
    }
};

pub fn ActionBuilder(comptime STATE: type) type {
    return ActionBuilderOffset(STATE, 0);
}

pub fn ActionBuilderOffset(comptime STATE: type, offset: u32) type {
    return struct {
        const Self = @This();
        action: Action,

        pub fn new(action_tag: anytype) Self {
            const ty: u32 = switch (@typeInfo(@TypeOf(action_tag))) {
                .@"enum" => @intFromEnum(action_tag),
                .comptime_int, .int => @intCast(action_tag),
                else => @compileError("ActionBuilder.new expects enum value or integer"),
            };

            return .{
                .action = .{ .ty = ty + offset },
            };
        }

        pub fn solve(self: Self, val: STATE) Self {
            var s = self;
            s.action.solves.set(@intFromEnum(val));
            return s;
        }

        pub fn require(self: Self, val: STATE) Self {
            var s = self;
            s.action.requires.set(@intFromEnum(val));
            return s;
        }

        pub fn requireOnce(self: Self, val: STATE) Self {
            var s = self;
            s.action.requires.set(@intFromEnum(val));
            s.action.clears.set(@intFromEnum(val));
            return s;
        }

        pub fn forbid(self: Self, val: STATE) Self {
            var s = self;
            s.action.forbids.set(@intFromEnum(val));
            return s;
        }

        pub fn clear(self: Self, val: STATE) Self {
            var s = self;
            s.action.clears.set(@intFromEnum(val));
            return s;
        }

        pub fn get(self: Self) Action {
            return self.action;
        }
    };
}

pub const Plan = struct {
    //todo: replace with bool array,
    actions: [16]Action = @splat(.{ .ty = 999999 }),
    needs_solving: StateMask = .initEmpty(),
    fulfilled: StateMask = .initEmpty(),
    world: StateMask = .initEmpty(),
    len: u32 = 0,

    fn last(self: *Plan) Action {
        return self.actions[self.len -| 1];
    }

    pub fn print(self: *const Plan, comptime Actions: type) void {
        for (0..self.len) |i| {
            const tag: Actions = @enumFromInt(self.actions[i].ty);
            std.debug.print("[{d}] {s}\n", .{ i, @tagName(tag) });
        }
    }

    fn providedStates(self: *const Plan) StateMask {
        var provided = StateMask.initEmpty();
        for (0..self.len) |i| {
            provided = provided.unionWith(self.actions[i].solves);
        }
        return provided;
    }

    fn cost(self: *const Plan) f32 {
        var total: f32 = 0;
        for (0..self.len) |i| {
            total += self.actions[i].cost;
        }
        return total;
    }

    pub fn sliceConst(self: *const Plan) []const Action {
        return self.actions[0..self.len];
    }

    pub fn slice(self: *Plan) []Action {
        return self.actions[0..self.len];
    }

    fn append(self: *Plan, action: Action) void {
        assert(self.len < self.actions.len);
        self.actions[self.len] = action;
        self.len += 1;

        self.needs_solving = self.needs_solving.differenceWith(action.solves);
        const new_requirements = action.requires.differenceWith(self.fulfilled);
        self.needs_solving = self.needs_solving.unionWith(new_requirements);
    }

    pub fn step(self: *const Plan, i: u32) ?Action {
        if (i >= self.len) return null;
        const index = self.len - i - 1;
        return self.actions[index];
    }

    pub fn empty(self: *Plan) bool {
        return self.len == 0;
    }
};

pub const Planner = struct {
    const Self = @This();

    goal: StateMask = .initEmpty(),
    world: StateMask = .initEmpty(),
    cost_solver: CostSolver = CostSolver.Default,

    pub fn plan(self: Self, available: []const Action) !Plan {
        return planGoal(self.goal, self.world, available, self.cost_solver);
    }

    pub fn new(comptime goal: anytype, comptime world: anytype) Self {
        var goal_mask = StateMask.initEmpty();
        var world_mask = StateMask.initEmpty();

        inline for (goal) |ebit| goal_mask.set(@intFromEnum(ebit));
        inline for (world) |ebit| world_mask.set(@intFromEnum(ebit));

        return Self{
            .goal = goal_mask,
            .world = world_mask,
        };
    }
};

pub const CostSolver = struct {
    ptr: *anyopaque,
    solve: *const fn (p: *anyopaque, action: Action) f32,

    pub const Default: CostSolver = .{
        .ptr = undefined,
        .solve = (struct {
            fn solve(_: *anyopaque, action: Action) f32 {
                return action.cost;
            }
        }).solve,
    };
};

pub const PlanContext = struct {
    goal: Goal,
    world: StateMask,
    avilable_actions: []const Action,
    cost_solver: CostSolver = CostSolver.Default,
};

pub fn planGoal(
    goal: StateMask,
    world: StateMask,
    available: []const Action,
    solver: CostSolver,
) !Plan {
    var plans: [32]Plan = undefined;
    var runnig_plans = std.ArrayList(Plan).initBuffer(&plans);

    // Producible = every bit any action claims to solve. A required bit
    // outside (producible ∪ world) can never be satisfied from here, so any
    // plan carrying such a bit in needs_solving is dead and must be pruned
    // before it can inflate the buffer or slip through selection.
    var producible: StateMask = .initEmpty();
    for (available) |a| producible = producible.unionWith(a.solves);
    const reachable = producible.unionWith(world);

    // Initialize with world state as already fulfilled
    const first_plan: Plan = .{
        .needs_solving = goal.differenceWith(world),
        .fulfilled = world,
        .world = world,
    };
    if (!first_plan.needs_solving.differenceWith(reachable).eql(.initEmpty())) {
        return error.UnreachableGoal;
    }
    try runnig_plans.appendBounded(first_plan);

    blk: while (true) {
        var progressed = false;
        // -------------------
        const size = runnig_plans.items.len;

        for (0..size) |i| {
            //in reverse
            const index = size - i - 1;
            const plan: *Plan = &runnig_plans.items[index];

            // Dead branch: a remaining requirement is not producible and not
            // in the world. Drop before spending more buffer on it.
            if (!plan.needs_solving.differenceWith(reachable).eql(.initEmpty())) {
                _ = runnig_plans.swapRemove(index);
                continue;
            }

            // replace with
            if (plan.needs_solving.mask == 0) continue;

            const solve = plan.needs_solving.differenceWith(plan.fulfilled);
            var it = SolveIter{ .solve = solve, .available = available };

            var next_action = it.next() orelse {
                _ = runnig_plans.swapRemove(index);
                continue;
            };

            next_action.cost = solver.solve(solver.ptr, next_action);

            // fork children
            frk: while (it.next()) |other_action| {
                var fork = plan.*;

                if (!other_action.forbids.intersectWith(plan.world).eql(.initEmpty())) {
                    continue;
                }

                var next_other = other_action;
                next_other.cost = solver.solve(solver.ptr, next_other);

                fork.append(next_other);
                runnig_plans.appendBounded(fork) catch {
                    std.log.warn("planner hit capacity limit, voiding options", .{});
                    // no more buffer space
                    break :frk;
                };
            }

            progressed = true;
            plan.append(next_action);
        }
        // -------------------
        if (!progressed) break :blk;
    }

    // Find the best valid plan (shortest length, lowest cost). A plan is
    // valid only if its simulated end-state actually contains every goal
    // bit: `needs_solving == 0` alone is not enough when clears can drop
    // previously-solved bits during execution.
    var best_plan: ?Plan = null;
    for (runnig_plans.items) |p| {
        if (p.needs_solving.mask != 0) continue;
        if (!simulatePlan(p, world).intersectWith(goal).eql(goal)) continue;
        if (best_plan == null or p.cost() < best_plan.?.cost()) {
            best_plan = p;
        }
    }

    if (best_plan) |plan| return plan;
    return error.UnreachableGoal;
}

/// Replay a plan's actions in execution order (last-appended first, matching
/// `Plan.step`) and return the resulting world state. Used for post-plan
/// goal validation so we don't trust `needs_solving` alone.
fn simulatePlan(plan: Plan, start: StateMask) StateMask {
    var w = start;
    var i: u32 = plan.len;
    while (i > 0) {
        i -= 1;
        w = plan.actions[i].finish(w);
    }
    return w;
}

pub const SolveIter = struct {
    solve: StateMask,
    available: []const Action,
    i: u32 = 0,

    pub fn next(self: *SolveIter) ?Action {
        if (self.i >= self.available.len) return null;

        const current_solve = self.available[self.i].solves;

        if (current_solve.intersectWith(self.solve).mask != 0) {
            const next_action = self.available[self.i];
            self.i += 1;
            return next_action;
        }

        self.i += 1;
        return next(self);
    }
};

pub fn Enum(comptime E: type, flags: anytype) StateMask {
    var mask = StateMask.initEmpty();
    inline for (flags) |flag| {
        mask.set(@intFromEnum(@as(E, flag)));
    }
    return mask;
}

pub fn Mask(comptime E: type) MaskBuilder(E) {
    return MaskBuilder(E){};
}

pub fn MaskBuilder(comptime E: type) type {
    return struct {
        mask: StateMask = .initEmpty(),
        pub fn new() @This() {
            return .{ .mask = .initEmpty() };
        }
        pub fn set(self: @This(), s: E) @This() {
            var m = self;
            m.mask.set(@intFromEnum(s));
            return m;
        }
    };
}

test "test planner" {
    const S = enum {
        has_axe,
        has_wood,
        has_meat,
        has_berries,
        can_cook,
        can_eat,
    };

    const A = enum {
        get_axe,
        chop_wood,
        cook,
        create_fire,
        hunt,
        collect,
    };

    const brain = Planner.new(.{S.can_eat}, .{});
    const plan = try brain.plan(&.{
        Action.new(A.collect, .{S.has_berries}, .{}, .{}),
        Action.new(A.get_axe, .{S.has_axe}, .{}, .{}),
        Action.new(A.chop_wood, .{S.has_wood}, .{S.has_axe}, .{}),
        Action.new(A.hunt, .{S.has_meat}, .{S.has_axe}, .{}),
        Action.new(A.create_fire, .{S.can_cook}, .{S.has_wood}, .{}),
        Action.new(A.cook, .{S.can_eat}, .{ S.can_cook, S.has_meat, S.has_berries }, .{}),
    });
    plan.print(A);
}

pub const BaseCtx = struct {
    const kn = @import("root.zig").kn;

    entity: kn.Entity,
    agent: *Agent,
    meta: kn.Meta,
    cmd: kn.Commands,
};

/// action category set Vtable
pub const BrainVSet = struct {
    name: []const u8,
    actions: []const Action,
    goals: []const Goal,
    state_count: u32 = 0,
    goal_ctx_size: usize = 0,
    goal_ctx_align: usize = 1,

    goal_valid: *const fn (local_goal: u32, view: *anyopaque) bool,
    set_goal: *const fn (local_goal: u32, agent: *Agent, view: *anyopaque, goal_ctx: *anyopaque) void,
    startup: *const fn (local_action: u32, base: *BaseCtx, set_ctx: *anyopaque, goal_ctx: *anyopaque) anyerror!void,
    finished: *const fn (local_action: u32, base: *BaseCtx, set_ctx: *anyopaque, goal_ctx: *anyopaque) anyerror!bool,
    fail: ?*const fn (local_action: u32, base: *BaseCtx, set_ctx: *anyopaque, goal_ctx: *anyopaque) anyerror!void = null,
    /// Optional: project live world facts onto the agent's state bitmask.
    /// Called once per tick, before goal selection and before `tick`. This is
    /// where preconditions that aren't produced by prior action effects get
    /// synced (e.g. `has_overflow`, `is_tired`). The `agent` argument is a
    /// set-scoped view: `agent.setState(MySet.State.foo, …)` writes the
    /// correct global bit even when the set isn't registered first. The
    /// opaque view pointer matches the one passed to `goal_valid` / `set_goal`.
    collect_state: ?*const fn (view: *anyopaque, agent: AgentSetView) void = null,
    /// Optional: score a viable goal. Higher wins. Plan cost is provided so
    /// callers can fold it in (e.g. `score - cost * k`). When absent a default
    /// score is used: registration order descending, minus a small bias if
    /// this goal was the last one completed.
    score_goal: ?*const fn (local_goal: u32, view: *anyopaque, agent: *const Agent, plan_cost: f32) f32 = null,
    /// Optional: dynamic per-action cost. `local_action` is the set-local
    /// action id (same space as `startup` / `finished`). Lower cost wins
    /// during plan selection. When absent the planner uses `Action.cost`.
    score_action: ?*const fn (local_action: u32, view: *anyopaque, agent: *const Agent) f32 = null,
    /// Optional teardown hook. Called once per registered set from
    /// `Brain.deinit`. Use for releasing module-level state the set owns
    /// (cached handles, registered assets). Per-agent `set_ctx` is owned by
    /// the caller of `Brain.run` and is NOT passed here.
    deinit: ?*const fn (gpa: std.mem.Allocator) void = null,
};

pub const BrainSetState = struct {
    name: []const u8,
    action_offset: u32,
    goal_offset: u32,
    state_offset: u32,
    state_count: u32,
};

fn shiftMask(mask: StateMask, by: u32) StateMask {
    return .{ .mask = mask.mask << @intCast(by) };
}

pub fn Brain(comptime tag: []const u8) type {
    return struct {
        pub const Tag = tag;
        const Self = @This();
        pub const SetId = enum(u32) { _ };
        const SetEntry = struct { state: BrainSetState, vtable: BrainVSet };
        const ActionEntry = struct { action: Action, id: SetId };
        const GoalEntry = struct { goal: Goal, id: SetId };

        sets: std.MultiArrayList(SetEntry) = .{},
        actions: std.MultiArrayList(ActionEntry) = .{},
        goals: std.MultiArrayList(GoalEntry) = .{},

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            const slice = self.sets.slice();
            for (0..self.sets.len) |i| {
                const entry = slice.get(i);
                if (entry.vtable.deinit) |fn_deinit| fn_deinit(gpa);
            }
            self.sets.deinit(gpa);
            self.actions.deinit(gpa);
            self.goals.deinit(gpa);
        }

        pub fn registerSet(self: *Self, gpa: std.mem.Allocator, set: BrainVSet) !SetId {
            std.debug.assert(set.goal_ctx_size <= GOAL_CTX_MAX);
            std.debug.assert(set.goal_ctx_align <= GOAL_CTX_ALIGN);

            const id: SetId = @enumFromInt(@as(u32, @intCast(self.sets.len)));
            const action_offset: u32 = @intCast(self.actions.len);
            const goal_offset: u32 = @intCast(self.goals.len);

            var state_offset: u32 = 0;
            const sets_slice = self.sets.slice();
            for (0..self.sets.len) |i| {
                const prior = sets_slice.get(i).state;
                state_offset += prior.state_count;
            }
            std.debug.assert(state_offset + set.state_count <= @bitSizeOf(StateMask.MaskInt));

            try self.sets.append(gpa, .{
                .state = .{
                    .name = set.name,
                    .action_offset = action_offset,
                    .goal_offset = goal_offset,
                    .state_offset = state_offset,
                    .state_count = set.state_count,
                },
                .vtable = set,
            });

            for (set.actions, 0..) |a, i| {
                // Trampolines decode `local = ty - action_offset` back into the
                // caller's Action enum via @enumFromInt. That only works when
                // each slice entry's builder-assigned `ty` matches its index.
                std.debug.assert(a.ty == @as(u32, @intCast(i)));
                var rewritten = a;
                rewritten.ty = action_offset + @as(u32, @intCast(i));
                rewritten.solves = shiftMask(a.solves, state_offset);
                rewritten.requires = shiftMask(a.requires, state_offset);
                rewritten.forbids = shiftMask(a.forbids, state_offset);
                rewritten.clears = shiftMask(a.clears, state_offset);
                try self.actions.append(gpa, .{ .action = rewritten, .id = id });
            }
            for (set.goals, 0..) |goal, i| {
                std.debug.assert(goal.ty == @as(u32, @intCast(i)));
                var rewritten = goal;
                rewritten.ty = goal_offset + @as(u32, @intCast(i));
                rewritten.desires = shiftMask(goal.desires, state_offset);
                rewritten.requires = shiftMask(goal.requires, state_offset);
                rewritten.forbids = shiftMask(goal.forbids, state_offset);
                rewritten.clears = shiftMask(goal.clears, state_offset);
                try self.goals.append(gpa, .{ .goal = rewritten, .id = id });
            }

            return id;
        }

        pub fn refreshSet(self: *Self, id: SetId, new_vtable: BrainVSet) void {
            const i = @intFromEnum(id);
            var slice = self.sets.slice();
            var entry = slice.get(i);
            // Only patch fn pointers, keep computed offsets/state intact
            entry.vtable.goal_valid = new_vtable.goal_valid;
            entry.vtable.set_goal = new_vtable.set_goal;
            entry.vtable.startup = new_vtable.startup;
            entry.vtable.finished = new_vtable.finished;
            entry.vtable.fail = new_vtable.fail;
            entry.vtable.collect_state = new_vtable.collect_state;
            entry.vtable.score_goal = new_vtable.score_goal;
            entry.vtable.score_action = new_vtable.score_action;
            entry.vtable.deinit = new_vtable.deinit;
            slice.set(i, entry);
        }

        const Args = struct {
            brain: *const Self,
            base: *BaseCtx,
            ctx: []const *anyopaque,
        };

        pub fn run(
            self: *const Self,
            dt: f32,
            base: *BaseCtx,
            ctx: []const *anyopaque,
        ) !void {
            var args = Args{ .brain = self, .base = base, .ctx = ctx };

            try base.agent.tick(dt, .{
                .ptr = &args,
                .on_startup = trampolineStartup,
                .is_finished = trampolineFinished,
                .on_fail = trampolineFail,
            });
        }

        fn trampolineStartup(ptr: *anyopaque, action: *const Action) !void {
            const args: *Args = @ptrCast(@alignCast(ptr));
            const aen = args.brain.actions.get(action.ty);
            const set_id: u32 = @intFromEnum(aen.id);
            const set = args.brain.sets.get(set_id);
            const local = aen.action.ty - set.state.action_offset;
            const goal_ctx: *anyopaque = @ptrCast(&args.base.agent.goal_ctx_buf);
            try set.vtable.startup(local, args.base, args.ctx[set_id], goal_ctx);
        }

        fn trampolineFinished(ptr: *anyopaque, action: *const Action) !bool {
            const args: *Args = @ptrCast(@alignCast(ptr));
            const aen = args.brain.actions.get(action.ty);
            const set_id: u32 = @intFromEnum(aen.id);
            const set = args.brain.sets.get(set_id);
            const local = aen.action.ty - set.state.action_offset;
            const goal_ctx: *anyopaque = @ptrCast(&args.base.agent.goal_ctx_buf);
            return try set.vtable.finished(local, args.base, args.ctx[set_id], goal_ctx);
        }

        fn trampolineFail(ptr: *anyopaque, action: *const Action) !void {
            const args: *Args = @ptrCast(@alignCast(ptr));
            const aen = args.brain.actions.get(action.ty);
            const set_id: u32 = @intFromEnum(aen.id);
            const set = args.brain.sets.get(set_id);
            const fail_fn = set.vtable.fail orelse return;
            const local = aen.action.ty - set.state.action_offset;
            const goal_ctx: *anyopaque = @ptrCast(&args.base.agent.goal_ctx_buf);
            try fail_fn(local, args.base, args.ctx[set_id], goal_ctx);
        }

        /// Run each set's optional `collect_state` hook so live world facts
        /// are projected onto the agent's bitmask before goal planning.
        pub fn collectStates(
            self: *const Self,
            agent: *Agent,
            ctx: []const *anyopaque,
        ) void {
            const sets_slice = self.sets.slice();
            for (0..self.sets.len) |si| {
                const set = sets_slice.get(si);
                const hook = set.vtable.collect_state orelse continue;
                hook(ctx[si], .{ .agent = agent, .state_offset = set.state.state_offset });
            }
        }

        pub fn planGoal(
            self: *const Self,
            agent: *Agent,
            ctx: []const *anyopaque,
        ) !void {
            if (agent.plan != null) return;

            const goals_slice = self.goals.slice();

            var best_score: f32 = -std.math.inf(f32);
            var best_plan: ?Plan = null;
            var best_goal_idx: ?usize = null;

            for (0..self.goals.len) |gi| {
                const entry = goals_slice.get(gi);
                if (agent.failed_goals.isSet(@intCast(gi))) continue;

                const set_id: u32 = @intFromEnum(entry.id);
                const set = self.sets.get(set_id);
                const local = entry.goal.ty - set.state.goal_offset;

                if (!set.vtable.goal_valid(local, ctx[set_id])) continue;
                if (!entry.goal.valid(agent.world)) continue;

                const SolverCtx = struct {
                    brain: *const Self,
                    set_ctx: []const *anyopaque,
                    agent: *const Agent,

                    fn solve(p: *anyopaque, action: Action) f32 {
                        const sc: *const @This() = @ptrCast(@alignCast(p));
                        const aen = sc.brain.actions.get(action.ty);
                        const sid: u32 = @intFromEnum(aen.id);
                        const s = sc.brain.sets.get(sid);
                        const fn_score = s.vtable.score_action orelse return action.cost;
                        const la = action.ty - s.state.action_offset;
                        return fn_score(la, sc.set_ctx[sid], sc.agent);
                    }
                };
                var solver_ctx = SolverCtx{ .brain = self, .set_ctx = ctx, .agent = agent };
                const planner = Planner{
                    .goal = entry.goal.desires,
                    .world = agent.world,
                    .cost_solver = .{ .ptr = &solver_ctx, .solve = SolverCtx.solve },
                };
                const plan = planner.plan(self.actions.items(.action)) catch continue;

                const cost = plan.cost();
                const score: f32 = if (set.vtable.score_goal) |fn_score|
                    fn_score(local, ctx[set_id], agent, cost)
                else blk: {
                    // Default: later-registered goals score lower. Small
                    // penalty if this was the last goal completed, so the
                    // agent rotates when another goal is equally valid.
                    var s: f32 = @as(f32, @floatFromInt(self.goals.len - gi));
                    if (agent.last_goal) |lg| if (lg == entry.goal.ty) {
                        s -= 0.1;
                    };
                    break :blk s;
                };

                if (score > best_score) {
                    best_score = score;
                    best_plan = plan;
                    best_goal_idx = gi;
                }
            }

            const gi = best_goal_idx orelse return;
            const entry = goals_slice.get(gi);
            const set_id: u32 = @intFromEnum(entry.id);
            const set = self.sets.get(set_id);
            const local = entry.goal.ty - set.state.goal_offset;

            agent.plan = best_plan;
            agent.step = 0;
            agent.current_action = null;
            agent.current_goal = entry.goal;
            agent.current_state = .startup;
            const goal_ctx: *anyopaque = @ptrCast(&agent.goal_ctx_buf);
            set.vtable.set_goal(local, agent, ctx[set_id], goal_ctx);
        }
    };
}
