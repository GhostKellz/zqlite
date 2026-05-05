const std = @import("std");
const compat = @import("compat/thread.zig");
const cancellation = @import("cancellation.zig");

pub const TaskContext = struct {
    cancel_token: ?*cancellation.CancelToken = null,

    pub fn checkpoint(self: TaskContext) !void {
        if (self.cancel_token) |token| {
            try token.checkpoint();
        }
    }

    pub fn isCancelled(self: TaskContext) bool {
        if (self.cancel_token) |token| {
            return token.isCancelled();
        }
        return false;
    }
};

const Job = struct {
    run_fn: *const fn (*anyopaque) void,
    destroy_fn: *const fn (*std.mem.Allocator, *anyopaque) void,
    payload: *anyopaque,
};

pub const Metrics = struct {
    worker_count: usize,
    active_jobs: usize,
    queued_jobs: usize,
    submitted_jobs: u64,
    completed_jobs: u64,
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .{},
    has_work: compat.Condition = .{},
    idle: compat.Condition = .{},
    queue: std.Deque(Job) = .empty,
    workers: std.ArrayListUnmanaged(std.Thread) = .empty,
    stopping: bool = false,
    active_jobs: usize = 0,
    submitted_jobs: u64 = 0,
    completed_jobs: u64 = 0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, worker_count: usize) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = Self{ .allocator = allocator };
        errdefer self.deinit();

        const count = if (worker_count == 0) 1 else worker_count;
        try self.workers.ensureTotalCapacity(allocator, count);

        var started: usize = 0;
        errdefer {
            self.stopping = true;
            self.has_work.broadcast();
            while (started > 0) : (started -= 1) {
                self.workers.items[started - 1].join();
            }
        }

        while (started < count) : (started += 1) {
            const thread = try std.Thread.spawn(.{}, workerMain, .{self});
            self.workers.appendAssumeCapacity(thread);
        }

        return self;
    }

    pub fn submit(self: *Self, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.stopping) return error.ExecutorStopped;

        try self.queue.pushBack(self.allocator, job);
        self.submitted_jobs += 1;
        self.has_work.signal();
    }

    pub fn waitIdle(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.len != 0 or self.active_jobs != 0) {
            self.idle.wait(&self.mutex);
        }
    }

    pub fn shutdown(self: *Self) void {
        self.mutex.lock();
        if (self.stopping) {
            self.mutex.unlock();
            return;
        }
        self.stopping = true;
        self.has_work.broadcast();
        self.mutex.unlock();

        for (self.workers.items) |thread| {
            thread.join();
        }

        self.mutex.lock();
        while (self.queue.popFront()) |job| {
            job.destroy_fn(&self.allocator, job.payload);
        }
        self.mutex.unlock();
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.queue.deinit(self.allocator);
        self.workers.deinit(self.allocator);
    }

    pub fn getMetrics(self: *Self) Metrics {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .worker_count = self.workers.items.len,
            .active_jobs = self.active_jobs,
            .queued_jobs = self.queue.len,
            .submitted_jobs = self.submitted_jobs,
            .completed_jobs = self.completed_jobs,
        };
    }

    fn workerMain(self: *Self) void {
        while (true) {
            self.mutex.lock();
            while (self.queue.len == 0 and !self.stopping) {
                self.has_work.wait(&self.mutex);
            }

            if (self.queue.len == 0 and self.stopping) {
                self.mutex.unlock();
                return;
            }

            const job = self.queue.popFront().?;
            self.active_jobs += 1;
            self.mutex.unlock();

            job.run_fn(job.payload);
            job.destroy_fn(&self.allocator, job.payload);

            self.mutex.lock();
            self.active_jobs -= 1;
            self.completed_jobs += 1;
            if (self.queue.len == 0 and self.active_jobs == 0) {
                self.idle.broadcast();
            }
            self.mutex.unlock();
        }
    }
};
