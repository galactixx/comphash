const std = @import("std");
const zh = @import("zighash");

/// probing strategies for the hash map.
pub const Prober = enum {
    Linear,
    DoubleHash,
    Bidirectional,
    Triangular,
};

/// returns the probing function for the given Prober strategy.
fn getProber(prober: Prober) fn (base: u64, i: u64, _: u64) u64 {
    return switch (prober) {
        .Linear => struct {
            /// linear probing: next = base + i
            pub fn function(base: u64, i: u64, _: u64) u64 {
                return base +% i;
            }
        }.function,
        .DoubleHash => struct {
            /// doublehashing additionally using cityHash64.
            pub fn function(base: u64, i: u64, step: u64) u64 {
                return base +% i *% step;
            }
        }.function,
        .Bidirectional => struct {
            /// bidirectional probing: alternates forward/backward offsets
            pub fn function(base: u64, i: u64, _: u64) u64 {
                const half: u64 = i / 2 + 1;
                const offset: u64 = if (i & 1 == 1) base -% half else base +% half;
                return offset;
            }
        }.function,
        .Triangular => struct {
            /// triangular probing: next = base + (i * (i + 1) / 2).
            pub fn function(base: u64, i: u64, _: u64) u64 {
                const offset = (i *% (i +% 1)) / 2;
                return base +% offset;
            }
        }.function,
    };
}

/// default hash function using xxHash64 with seed 0.
fn defaultHasher(key: []const u8) u64 {
    return zh.xxHash64(key, 0);
}

/// default equality comparator for byte slices.
fn defaultEql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// generates a compile-time hash map type for key/value pairs
/// known at comptime.
pub fn ComptimeHashMap(
    comptime V: type,
    comptime hasher: ?fn ([]const u8) u64,
    comptime prober: ?Prober,
    comptime eql: ?fn ([]const u8, []const u8) bool,
) type {
    // set the default hash, probe, and equality methods if not provided.
    const hash_method = hasher orelse defaultHasher;
    const probe = prober orelse Prober.Linear;
    const probe_method = getProber(probe);
    const eql_method = eql orelse defaultEql;

    // define the pair type for the key-value pairs.
    const Pair = struct { key: []const u8, value: V };

    // define the key-value pair union for the table.
    const KVPair = union(enum) {
        Empty,
        Occupied: Pair,
    };

    return struct {
        const Self = @This();

        hasher: fn ([]const u8) u64,
        prober: fn (base: u64, i: u64, _: u64) u64,
        eqler: fn ([]const u8, []const u8) bool,
        map_table: []const KVPair,
        map_items: []const Pair,
        map_cap: u64,

        /// iterator type generator: yields type-specific iterators.
        fn Iterator(comptime R: type) type {
            const getter: fn (pair: Pair) R = switch (R) {
                V => struct {
                    /// extract the value from a pair.
                    pub fn getter(pair: Pair) V {
                        return pair.value;
                    }
                }.getter,
                []const u8 => struct {
                    /// extract the key from a pair.
                    pub fn getter(pair: Pair) []const u8 {
                        return pair.key;
                    }
                }.getter,
                else => struct {
                    /// return the full pair.
                    pub fn getter(pair: Pair) Pair {
                        return pair;
                    }
                }.getter,
            };

            return struct {
                const IterSelf = @This();

                data: []const Pair,
                idx: usize,
                getter: *const fn (pair: Pair) R,

                /// initialize iterator with a slice of pairs.
                fn init(data: []const Pair) IterSelf {
                    return IterSelf{ .data = data, .idx = 0, .getter = getter };
                }

                /// return next element or null when done.
                pub fn next(self: *IterSelf) ?R {
                    if (self.idx >= self.data.len) return null;
                    const pair: Pair = self.data[self.idx];
                    self.idx += 1;
                    return self.getter(pair);
                }
            };
        }

        /// build and return a new map instance, filling the table and items.
        pub fn init(comptime kv_pairs: []const struct { []const u8, V }) Self {
            if (kv_pairs.len == 0) {
                @compileError("no key-value pairs supplied");
            }

            // calculate the initial capacity based on the number of key-value pairs.
            const len_float: f64 = @floatFromInt(kv_pairs.len);
            const init_cap: u64 = @intFromFloat(len_float / 0.7);
            const M = try std.math.ceilPowerOfTwo(u64, init_cap);

            // check to ensure that there are no duplicate keys.
            for (kv_pairs, 0..) |kv1, i| {
                for (kv_pairs[i + 1 ..]) |kv2| {
                    if (eql_method(kv1[0], kv2[0])) {
                        @compileError("there are duplicate keys for " + kv1[0]);
                    }
                }
            }

            // initialize the items and table with the initial capacity.
            var init_items: [kv_pairs.len]Pair = undefined;
            var init_table: [M]KVPair = [_]KVPair{KVPair.Empty} ** M;

            // insert the key-value pairs into the table using the hash function
            // and probe method.
            for (kv_pairs, 0..) |kv_pair, idx| {
                const computed_hash = hash_method(kv_pair[0]);
                const second_hash: u64 = switch (probe) {
                    .DoubleHash => zh.cityHash64(kv_pair[0]) | 1,
                    else => undefined,
                };

                // calculate the base index for the hash function.
                const base_index = computed_hash & (M - 1);
                var i: u64 = 0;
                var bucket_idx: u64 = base_index;

                // probe until an empty slot is found.
                while (switch (init_table[bucket_idx]) {
                    .Empty => false,
                    .Occupied => true,
                }) : (i += 1) {
                    bucket_idx = probe_method(base_index, i, second_hash) & (M - 1);
                }

                // insert the key-value pair into the table at the calculated index.
                const pair = Pair{ .key = kv_pair[0], .value = kv_pair[1] };
                init_table[bucket_idx] = KVPair{ .Occupied = pair };
                init_items[idx] = pair;
            }

            // return the map instance with the initialized table and items.
            const map_table = init_table;
            const map_items = init_items;
            return Self{
                .hasher = hash_method,
                .prober = probe_method,
                .eqler = eql_method,
                .map_table = &map_table,
                .map_items = &map_items,
                .map_cap = M,
            };
        }

        /// returns a read-only slice of all key/value pairs in the order of insertion.
        pub fn toSlice(self: *const Self) []const Pair {
            return self.map_items[0..];
        }

        /// return an iterator over keys in the order of insertion.
        pub fn keys(self: Self) Iterator([]const u8) {
            const Keys = Iterator([]const u8);
            return Keys.init(self.map_items[0..]);
        }

        /// return an iterator over values in the order of insertion.
        pub fn values(self: Self) Iterator(V) {
            const Values = Iterator(V);
            return Values.init(self.map_items[0..]);
        }

        /// return an iterator over key/value pairs in the order of insertion.
        pub fn items(self: Self) Iterator(Pair) {
            const Items = Iterator(Pair);
            return Items.init(self.map_items[0..]);
        }

        /// check if a key exists in the map for a given key.
        pub fn contains(self: Self, key: []const u8) bool {
            return self.getIndex(key) != null;
        }

        /// number of entries in the map.
        pub fn length(self: Self) usize {
            return self.map_items.len;
        }

        /// check if the map has no entries.
        pub fn isEmpty(self: Self) bool {
            return self.length() == 0;
        }

        /// return the underlying table capacity.
        pub fn capacity(self: Self) u64 {
            return self.map_cap;
        }

        /// find the bucket index for a key, or null if missing.
        pub fn getIndex(self: Self, key: []const u8) ?usize {
            var i: usize = 0;
            const key_hash: u64 = hash_method(key);
            const base_idx = key_hash & (self.map_cap - 1);
            var bucket_idx = base_idx;
            var found_key = false;

            // calculate the second hash for doublehashing if enabled.
            const second_hash: u64 = switch (probe) {
                .DoubleHash => zh.cityHash64(key) | 1,
                else => undefined,
            };

            // probe until an empty slot is found or the key is found.
            while (i < self.length()) {
                switch (self.map_table[bucket_idx]) {
                    .Empty => break,
                    .Occupied => |kv_pair| {
                        if (eql_method(kv_pair.key, key)) {
                            found_key = true;
                            break;
                        }
                        bucket_idx = probe_method(base_idx, i, second_hash) & (self.map_cap - 1);
                        i += 1;
                    },
                }
            }

            return if (found_key) bucket_idx else null;
        }

        /// get the value for a key, or null if not found.
        pub fn get(self: Self, key: []const u8) ?V {
            const idx = self.getIndex(key) orelse return null;
            const bucket = self.map_table[idx];
            return switch (bucket) {
                .Occupied => |kv_pair| kv_pair.value,
                .Empty => null,
            };
        }
    };
}

test "basic get/contains/length" {
    const kv: []const struct { []const u8, u32 } = &.{
        .{ "apple", 10 },
        .{ "banana", 20 },
        .{ "cherry", 30 },
    };
    const FruitMap = ComptimeHashMap(u32, null, null, null);
    const map = FruitMap.init(kv);

    try std.testing.expect(!map.isEmpty());
    try std.testing.expect(map.length() == kv.len);
    try std.testing.expect(map.contains("apple"));
    try std.testing.expect(map.get("apple") orelse 0 == 10);
    try std.testing.expect(map.get("banana") orelse 0 == 20);
    try std.testing.expect(map.get("durian") == null);
}

test "probe strategies consistency" {
    const kv: []const struct { []const u8, u32 } = &.{
        .{ "x", 100 },
        .{ "y", 200 },
    };
    const QMap = ComptimeHashMap(u32, null, Prober.Bidirectional, null);
    const map_q = QMap.init(kv);
    try std.testing.expect(map_q.get("x") orelse 0 == 100);
    try std.testing.expect(map_q.get("y") orelse 0 == 200);

    const RMap = ComptimeHashMap(u32, null, Prober.DoubleHash, null);
    const map_r = RMap.init(kv);
    try std.testing.expect(map_r.get("x") orelse 0 == 100);
    try std.testing.expect(map_r.get("y") orelse 0 == 200);
}

test "toSlice integrity" {
    const kv: []const struct { []const u8, u8 } = &.{
        .{ "a", 1 },
        .{ "bb", 2 },
        .{ "ccc", 3 },
    };
    const Map = ComptimeHashMap(u8, null, null, null);
    const map = Map.init(kv);

    const slice = map.toSlice();
    try std.testing.expect(slice.len == kv.len);
    for (slice, 0..) |pair, i| {
        try std.testing.expect(std.mem.eql(u8, pair.key, kv[i][0]));
        try std.testing.expect(pair.value == kv[i][1]);
    }
}

test "iterator order keys" {
    const kv: []const struct { []const u8, u8 } = &.{
        .{ "a", 1 },
        .{ "bb", 2 },
        .{ "ccc", 3 },
    };
    const Map = ComptimeHashMap(u8, null, null, null);
    const map = Map.init(kv);

    var it = map.keys();
    var idx: usize = 0;
    while (it.next()) |k| : (idx += 1) {
        try std.testing.expect(std.mem.eql(u8, k, kv[idx][0]));
    }
    try std.testing.expect(idx == kv.len);
}

test "iterator order values" {
    const kv: []const struct { []const u8, u8 } = &.{
        .{ "a", 1 },
        .{ "bb", 2 },
        .{ "ccc", 3 },
    };
    const Map = ComptimeHashMap(u8, null, null, null);
    const map = Map.init(kv);

    var it = map.values();
    var idx: usize = 0;
    while (it.next()) |v| : (idx += 1) {
        try std.testing.expect(v == kv[idx][1]);
    }
    try std.testing.expect(idx == kv.len);
}

test "capacity is power-of-two and ≥ 2×length" {
    const kv: []const struct { []const u8, u32 } = &.{
        .{ "one", 1 },
        .{ "two", 2 },
        .{ "three", 3 },
        .{ "four", 4 },
    };
    const Map = ComptimeHashMap(u32, null, null, null);
    const map = Map.init(kv);
    try std.testing.expect((map.capacity() & (map.capacity() - 1)) == 0);
}

test "bidirectional and triangular probing" {
    const kv: []const struct { []const u8, u32 } = &.{
        .{ "x", 1 }, .{ "y", 2 }, .{ "z", 3 },
    };

    const BiMapT = ComptimeHashMap(u32, null, Prober.Bidirectional, null);
    const bi = BiMapT.init(kv);
    try std.testing.expect(bi.get("x") orelse 0 == 1);
    try std.testing.expect(bi.get("z") orelse 0 == 3);

    const TriMapT = ComptimeHashMap(u32, null, Prober.Triangular, null);
    const tri = TriMapT.init(kv);
    try std.testing.expect(tri.get("y") orelse 0 == 2);
    try std.testing.expect(tri.contains("z"));
}

fn lenHash(key: []const u8) u64 {
    return key.len;
}
fn lenEq(a: []const u8, b: []const u8) bool {
    return a.len == b.len;
}

test "custom hash and equality" {
    const kv: []const struct { []const u8, u32 } = &.{
        .{ "a", 10 },
        .{ "bb", 20 },
        .{ "ccc", 30 },
    };
    const LenMapT = ComptimeHashMap(u32, lenHash, null, lenEq);
    const len_map = LenMapT.init(kv);

    try std.testing.expect(len_map.get("zz") orelse 0 == 20);
    try std.testing.expect(len_map.get("XYZ") orelse 0 == 30);
    try std.testing.expect(len_map.get("QRSD") == null);
}
