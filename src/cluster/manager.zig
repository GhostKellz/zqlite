const std = @import("std");
const storage = @import("../db/storage.zig");
const mvcc = @import("../concurrent/mvcc_transactions.zig");
const hot_standby = @import("../concurrent/hot_standby.zig");
const transport = @import("../transport/transport.zig");
const zsync = @import("zsync");
const time_utils = @import("../time_utils.zig");

/// Cluster Manager for Horizontal Scaling
/// Manages multiple nodes, load balancing, and cluster coordination
pub const ClusterManager = struct {
    allocator: std.mem.Allocator,
    cluster_id: []const u8,
    local_node: *Node,
    nodes: std.HashMap([]const u8, *Node),
    load_balancer: LoadBalancer,
    health_monitor: HealthMonitor,
    coordinator: ClusterCoordinator,
    shard_manager: ShardManager,
    replication_factor: u32,
    metrics: ClusterMetrics,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cluster_id: []const u8, local_node_id: []const u8) !Self {
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const local_node = try allocator.create(Node);
        local_node.* = Node{
            .id = try allocator.dupe(u8, local_node_id),
            .address = try allocator.dupe(u8, "127.0.0.1"),
            .port = 8080,
            .role = .Primary,
            .status = .Healthy,
            .last_seen = timestamp,
            .load_factor = 0.0,
            .allocated_shards = .{},
        };

        return Self{
            .allocator = allocator,
            .cluster_id = try allocator.dupe(u8, cluster_id),
            .local_node = local_node,
            .nodes = std.HashMap([]const u8, *Node).init(allocator),
            .load_balancer = try LoadBalancer.init(allocator),
            .health_monitor = try HealthMonitor.init(allocator),
            .coordinator = try ClusterCoordinator.init(allocator),
            .shard_manager = try ShardManager.init(allocator),
            .replication_factor = 3,
            .metrics = ClusterMetrics.init(),
        };
    }

    /// Add node to cluster
    pub fn addNode(self: *Self, node_id: []const u8, address: []const u8, port: u16) !void {
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const node = try self.allocator.create(Node);
        node.* = Node{
            .id = try self.allocator.dupe(u8, node_id),
            .address = try self.allocator.dupe(u8, address),
            .port = port,
            .role = .Standby,
            .status = .Healthy,
            .last_seen = timestamp,
            .load_factor = 0.0,
            .allocated_shards = .{},
        };

        try self.nodes.put(node.id, node);
        try self.load_balancer.addNode(node);
        try self.health_monitor.addNode(node);

        // Trigger shard rebalancing
        try self.rebalanceShards();

        self.metrics.nodes_added += 1;
        self.metrics.active_nodes = self.nodes.count() + 1; // +1 for local node
    }

    /// Remove node from cluster
    pub fn removeNode(self: *Self, node_id: []const u8) !void {
        if (self.nodes.get(node_id)) |node| {
            // Redistribute shards from this node
            try self.redistributeShards(node);

            // Remove from components
            self.load_balancer.removeNode(node);
            self.health_monitor.removeNode(node);

            // Clean up node
            self.allocator.free(node.id);
            self.allocator.free(node.address);
            node.allocated_shards.deinit(self.allocator);
            self.allocator.destroy(node);

            _ = self.nodes.remove(node_id);

            self.metrics.nodes_removed += 1;
            self.metrics.active_nodes = self.nodes.count() + 1;
        }
    }

    /// Route query to appropriate node
    pub fn routeQuery(self: *Self, query: ClusterQuery) !QueryResult {
        const ts_start = time_utils.getTimespec();
        const start_time: i64 = @intCast(@divTrunc((@as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec), 1000));

        // Determine target nodes based on query
        const target_nodes = try self.determineTargetNodes(query);
        defer self.allocator.free(target_nodes);

        var results: std.ArrayList(QueryResult) = .{};
        defer results.deinit(self.allocator);

        // Execute query on target nodes
        for (target_nodes) |node| {
            const result = try self.executeQueryOnNode(node, query);
            try results.append(self.allocator, result);
        }

        // Merge results
        const merged_result = try self.mergeResults(results.items);

        const ts_end = time_utils.getTimespec();
        const end_time: i64 = @intCast(@divTrunc((@as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec), 1000));
        const execution_time = end_time - start_time;

        // Update metrics
        self.metrics.queries_processed += 1;
        self.metrics.total_query_time_us += execution_time;
        self.metrics.average_query_time_us = self.metrics.total_query_time_us / self.metrics.queries_processed;

        return merged_result;
    }

    /// Scale cluster up by adding nodes
    pub fn scaleUp(self: *Self, target_nodes: u32) !void {
        const current_nodes = self.nodes.count() + 1;
        if (target_nodes <= current_nodes) {
            return error.InvalidTargetCount;
        }

        const nodes_to_add = target_nodes - current_nodes;

        for (0..nodes_to_add) |i| {
            const node_id = try std.fmt.allocPrint(self.allocator, "node_{d}", .{current_nodes + i});
            defer self.allocator.free(node_id);

            const address = try self.allocator.dupe(u8, "127.0.0.1");
            const port: u16 = @intCast(8080 + current_nodes + i);

            try self.addNode(node_id, address, port);
        }

        self.metrics.scale_up_operations += 1;
    }

    /// Scale cluster down by removing nodes
    pub fn scaleDown(self: *Self, target_nodes: u32) !void {
        const current_nodes = self.nodes.count() + 1;
        if (target_nodes >= current_nodes or target_nodes == 0) {
            return error.InvalidTargetCount;
        }

        const nodes_to_remove = current_nodes - target_nodes;

        // Select nodes to remove (prefer least loaded)
        const nodes_to_remove_list = try self.selectNodesForRemoval(nodes_to_remove);
        defer self.allocator.free(nodes_to_remove_list);

        for (nodes_to_remove_list) |node| {
            try self.removeNode(node.id);
        }

        self.metrics.scale_down_operations += 1;
    }

    /// Get cluster health status
    pub fn getClusterHealth(self: *Self) ClusterHealth {
        return self.health_monitor.getClusterHealth();
    }

    /// Get cluster metrics
    pub fn getMetrics(self: *Self) ClusterMetrics {
        return self.metrics;
    }

    /// Rebalance shards across nodes
    fn rebalanceShards(self: *Self) !void {
        const total_shards = self.shard_manager.getTotalShards();
        const active_nodes = self.nodes.count() + 1;

        if (active_nodes == 0) return;

        const shards_per_node = total_shards / active_nodes;
        const extra_shards = total_shards % active_nodes;

        var node_iterator = self.nodes.iterator();
        var node_index: u32 = 0;

        // Rebalance for regular nodes
        while (node_iterator.next()) |entry| {
            const node = entry.value_ptr.*;
            const target_shards = shards_per_node + (if (node_index < extra_shards) @as(u32, 1) else 0);

            try self.shard_manager.assignShardsToNode(node, target_shards);
            node_index += 1;
        }

        // Rebalance for local node
        const local_target_shards = shards_per_node + (if (node_index < extra_shards) @as(u32, 1) else 0);
        try self.shard_manager.assignShardsToNode(self.local_node, local_target_shards);
    }

    /// Redistribute shards from a node being removed
    fn redistributeShards(self: *Self, node: *Node) !void {
        const shards_to_redistribute = node.allocated_shards.items;

        // Find healthy nodes to take over shards
        var available_nodes: std.ArrayList(*Node) = .{};
        defer available_nodes.deinit(self.allocator);

        var node_iterator = self.nodes.iterator();
        while (node_iterator.next()) |entry| {
            const candidate = entry.value_ptr.*;
            if (candidate.status == .Healthy and candidate != node) {
                try available_nodes.append(self.allocator, candidate);
            }
        }

        if (self.local_node.status == .Healthy) {
            try available_nodes.append(self.allocator, self.local_node);
        }

        // Redistribute shards
        for (shards_to_redistribute, 0..) |shard_id, i| {
            const target_node = available_nodes.items[i % available_nodes.items.len];
            try self.shard_manager.reassignShard(shard_id, target_node);
        }
    }

    /// Determine target nodes for a query
    fn determineTargetNodes(self: *Self, query: ClusterQuery) ![]const *Node {
        return switch (query.query_type) {
            .Read => try self.getReadNodes(query),
            .Write => try self.getWriteNodes(query),
            .AdminQuery => try self.getAdminNodes(),
        };
    }

    /// Get nodes for read query
    fn getReadNodes(self: *Self, query: ClusterQuery) ![]const *Node {
        const shard_id = self.shard_manager.getShardForKey(query.table, query.key);
        return try self.shard_manager.getNodesForShard(shard_id);
    }

    /// Get nodes for write query
    fn getWriteNodes(self: *Self, query: ClusterQuery) ![]const *Node {
        const shard_id = self.shard_manager.getShardForKey(query.table, query.key);
        return try self.shard_manager.getWriteNodesForShard(shard_id);
    }

    /// Get nodes for admin query
    fn getAdminNodes(self: *Self) ![]const *Node {
        var nodes: std.ArrayList(*Node) = .{};

        var node_iterator = self.nodes.iterator();
        while (node_iterator.next()) |entry| {
            try nodes.append(self.allocator, entry.value_ptr.*);
        }

        try nodes.append(self.allocator, self.local_node);
        return try nodes.toOwnedSlice(self.allocator);
    }

    /// Execute query on specific node
    fn executeQueryOnNode(self: *Self, node: *Node, query: ClusterQuery) !QueryResult {
        _ = self;
        _ = node;
        _ = query;

        // Implementation would send query to node and return result
        return QueryResult{
            .success = true,
            .data = null,
            .error_message = null,
            .execution_time_us = 1000,
        };
    }

    /// Merge results from multiple nodes
    fn mergeResults(self: *Self, results: []const QueryResult) !QueryResult {
        _ = self;

        var merged = QueryResult{
            .success = true,
            .data = null,
            .error_message = null,
            .execution_time_us = 0,
        };

        for (results) |result| {
            if (!result.success) {
                merged.success = false;
                if (result.error_message) |msg| {
                    merged.error_message = msg;
                }
                break;
            }
            merged.execution_time_us = @max(merged.execution_time_us, result.execution_time_us);
        }

        return merged;
    }

    /// Select nodes for removal during scale down
    fn selectNodesForRemoval(self: *Self, count: u32) ![]const *Node {
        var candidates: std.ArrayList(*Node) = .{};
        defer candidates.deinit(self.allocator);

        var node_iterator = self.nodes.iterator();
        while (node_iterator.next()) |entry| {
            try candidates.append(self.allocator, entry.value_ptr.*);
        }

        // Sort by load factor (ascending - remove least loaded first)
        std.sort.pdq(*Node, candidates.items, {}, struct {
            fn lessThan(context: void, a: *Node, b: *Node) bool {
                _ = context;
                return a.load_factor < b.load_factor;
            }
        }.lessThan);

        const result = try self.allocator.alloc(*Node, count);
        for (result, 0..) |*node, i| {
            node.* = candidates.items[i];
        }

        return result;
    }

    pub fn deinit(self: *Self) void {
        // Clean up local node
        self.allocator.free(self.local_node.id);
        self.allocator.free(self.local_node.address);
        self.local_node.allocated_shards.deinit(self.allocator);
        self.allocator.destroy(self.local_node);

        // Clean up other nodes
        var node_iterator = self.nodes.iterator();
        while (node_iterator.next()) |entry| {
            const node = entry.value_ptr.*;
            self.allocator.free(node.id);
            self.allocator.free(node.address);
            node.allocated_shards.deinit(self.allocator);
            self.allocator.destroy(node);
        }

        self.nodes.deinit();
        self.allocator.free(self.cluster_id);
        self.load_balancer.deinit();
        self.health_monitor.deinit();
        self.coordinator.deinit();
        self.shard_manager.deinit();
    }
};

/// Cluster node representation
pub const Node = struct {
    id: []const u8,
    address: []const u8,
    port: u16,
    role: hot_standby.NodeRole,
    status: NodeStatus,
    last_seen: i64,
    load_factor: f64,
    allocated_shards: std.ArrayList(u32),
};

/// Node status
pub const NodeStatus = enum {
    Healthy,
    Unhealthy,
    Disconnected,
    Maintenance,
};

/// Load balancer
const LoadBalancer = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(*Node),
    round_robin_index: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .nodes = .{},
            .round_robin_index = 0,
        };
    }

    pub fn addNode(self: *Self, node: *Node) !void {
        try self.nodes.append(self.allocator, node);
    }

    pub fn removeNode(self: *Self, node: *Node) void {
        for (self.nodes.items, 0..) |n, i| {
            if (n == node) {
                _ = self.nodes.swapRemove(i);
                break;
            }
        }
    }

    pub fn getNextNode(self: *Self) ?*Node {
        if (self.nodes.items.len == 0) return null;

        const node = self.nodes.items[self.round_robin_index];
        self.round_robin_index = (self.round_robin_index + 1) % @as(u32, @intCast(self.nodes.items.len));

        return node;
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit(self.allocator);
    }
};

/// Health monitor
const HealthMonitor = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(*Node),
    health_check_interval_ms: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .nodes = .{},
            .health_check_interval_ms = 5000,
        };
    }

    pub fn addNode(self: *Self, node: *Node) !void {
        try self.nodes.append(self.allocator, node);
    }

    pub fn removeNode(self: *Self, node: *Node) void {
        for (self.nodes.items, 0..) |n, i| {
            if (n == node) {
                _ = self.nodes.swapRemove(i);
                break;
            }
        }
    }

    pub fn getClusterHealth(self: *Self) ClusterHealth {
        var healthy_nodes: u32 = 0;
        var unhealthy_nodes: u32 = 0;

        for (self.nodes.items) |node| {
            switch (node.status) {
                .Healthy => healthy_nodes += 1,
                .Unhealthy, .Disconnected => unhealthy_nodes += 1,
                .Maintenance => {},
            }
        }

        const total_nodes = healthy_nodes + unhealthy_nodes;
        const health_percentage = if (total_nodes > 0)
            (@as(f64, @floatFromInt(healthy_nodes)) / @as(f64, @floatFromInt(total_nodes))) * 100.0
        else
            100.0;

        return ClusterHealth{
            .healthy_nodes = healthy_nodes,
            .unhealthy_nodes = unhealthy_nodes,
            .total_nodes = total_nodes,
            .health_percentage = health_percentage,
        };
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit(self.allocator);
    }
};

/// Cluster coordinator
const ClusterCoordinator = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

/// Shard manager
const ShardManager = struct {
    allocator: std.mem.Allocator,
    total_shards: u32,
    shard_to_nodes: std.HashMap(u32, std.ArrayList(*Node)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .total_shards = 1024,
            .shard_to_nodes = std.HashMap(u32, std.ArrayList(*Node)).init(allocator),
        };
    }

    pub fn getTotalShards(self: *Self) u32 {
        return self.total_shards;
    }

    pub fn getShardForKey(self: *Self, table: []const u8, key: []const u8) u32 {
        _ = self;
        const hash = std.hash.Wyhash.hash(0, table);
        const key_hash = std.hash.Wyhash.hash(hash, key);
        return @intCast(key_hash % 1024);
    }

    pub fn assignShardsToNode(self: *Self, node: *Node, shard_count: u32) !void {
        _ = self;
        node.allocated_shards.clearRetainingCapacity();

        for (0..shard_count) |i| {
            try node.allocated_shards.append(self.allocator, @intCast(i));
        }
    }

    pub fn reassignShard(self: *Self, shard_id: u32, new_node: *Node) !void {
        try new_node.allocated_shards.append(self.allocator, shard_id);
    }

    pub fn getNodesForShard(self: *Self, shard_id: u32) ![]const *Node {
        _ = self;
        _ = shard_id;
        // Implementation would return nodes responsible for this shard
        return &[_]*Node{};
    }

    pub fn getWriteNodesForShard(self: *Self, shard_id: u32) ![]const *Node {
        _ = self;
        _ = shard_id;
        // Implementation would return write nodes for this shard
        return &[_]*Node{};
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.shard_to_nodes.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.shard_to_nodes.deinit();
    }
};

/// Cluster query
pub const ClusterQuery = struct {
    query_type: QueryType,
    table: []const u8,
    key: []const u8,
    data: ?[]const u8,
};

/// Query types
pub const QueryType = enum {
    Read,
    Write,
    AdminQuery,
};

/// Query result
pub const QueryResult = struct {
    success: bool,
    data: ?[]const u8,
    error_message: ?[]const u8,
    execution_time_us: u64,
};

/// Cluster health
pub const ClusterHealth = struct {
    healthy_nodes: u32,
    unhealthy_nodes: u32,
    total_nodes: u32,
    health_percentage: f64,
};

/// Cluster metrics
pub const ClusterMetrics = struct {
    nodes_added: u64,
    nodes_removed: u64,
    active_nodes: u32,
    queries_processed: u64,
    total_query_time_us: u64,
    average_query_time_us: u64,
    scale_up_operations: u64,
    scale_down_operations: u64,

    pub fn init() ClusterMetrics {
        return ClusterMetrics{
            .nodes_added = 0,
            .nodes_removed = 0,
            .active_nodes = 1,
            .queries_processed = 0,
            .total_query_time_us = 0,
            .average_query_time_us = 0,
            .scale_up_operations = 0,
            .scale_down_operations = 0,
        };
    }
};

// Tests
test "cluster manager basic operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cluster = try ClusterManager.init(allocator, "test_cluster", "node1");
    defer cluster.deinit();

    try testing.expect(cluster.metrics.active_nodes == 1);

    // Add a node
    try cluster.addNode("node2", "127.0.0.1", 8081);
    try testing.expect(cluster.metrics.active_nodes == 2);
    try testing.expect(cluster.metrics.nodes_added == 1);

    // Test health
    const health = cluster.getClusterHealth();
    try testing.expect(health.total_nodes >= 1);
}

test "cluster scaling operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cluster = try ClusterManager.init(allocator, "test_cluster", "node1");
    defer cluster.deinit();

    // Scale up
    try cluster.scaleUp(5);
    try testing.expect(cluster.metrics.active_nodes == 5);
    try testing.expect(cluster.metrics.scale_up_operations == 1);

    // Scale down
    try cluster.scaleDown(3);
    try testing.expect(cluster.metrics.active_nodes == 3);
    try testing.expect(cluster.metrics.scale_down_operations == 1);
}
