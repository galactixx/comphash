const std = @import("std");
const zh = @import("zighash");

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
            /// doublehashing additionally using cityHash64
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
            /// triangular probing: next = base + (i * (i + 1) / 2)
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
    const hashMethod = hasher orelse defaultHasher;
    const probe = prober orelse Prober.Linear;
    const probeMethod = getProber(probe);
    const eqlMethod = eql orelse defaultEql;

    const Pair = struct { key: []const u8, value: V };

    const KVPair = union(enum) {
        Empty,
        Occupied: Pair,
    };

    return struct {
        const Self = @This();

        hasher: fn ([]const u8) u64,
        prober: fn (base: u64, i: u64, _: u64) u64,
        eqler: fn ([]const u8, []const u8) bool,
        mapTable: []const KVPair,
        mapItems: []const Pair,
        mapCap: u64,

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
        pub fn init(comptime kvPairs: []const struct { []const u8, V }) Self {
            if (kvPairs.len == 0) {
                @compileError("no key-value pairs supplied");
            }

            const lenFloat: f64 = @floatFromInt(kvPairs.len);
            const initCap: u64 = @bitCast(lenFloat / 0.7);
            const M = try std.math.ceilPowerOfTwo(u64, initCap);

            // check to ensure that there are no duplicates keys
            for (kvPairs, 0..) |kv1, i| {
                for (kvPairs[i + 1 ..]) |kv2| {
                    if (eqlMethod(kv1[0], kv2[0])) {
                        @compileError("there are duplicate keys for {any}" + kv1[0]);
                    }
                }
            }

            var initItems: [kvPairs.len]Pair = undefined;
            var initTable: [M]KVPair = [_]KVPair{KVPair.Empty} ** M;

            for (kvPairs, 0..) |kvPair, idx| {
                const computedHash = hashMethod(kvPair[0]);
                const secondHash: u64 = switch (probe) {
                    .DoubleHash => zh.cityHash64(kvPair[0]) | 1,
                    else => undefined,
                };

                const baseIndex = computedHash & (M - 1);
                var i: u64 = 0;
                var bucketIdx: u64 = baseIndex;

                // Probe until an empty slot is found
                while (!(initTable[bucketIdx] == KVPair.Empty)) : (i += 1) {
                    bucketIdx = probeMethod(baseIndex, i, secondHash) & (M - 1);
                }

                const pair = Pair{ .key = kvPair[0], .value = kvPair[1] };
                initTable[bucketIdx] = KVPair{ .Occupied = pair };
                initItems[idx] = pair;
            }

            const mapTable = initTable;
            const mapItems = initItems;

            return Self{
                .hasher = hashMethod,
                .prober = probeMethod,
                .eqler = eqlMethod,
                .mapTable = &mapTable,
                .mapItems = &mapItems,
                .mapCap = M,
            };
        }

        /// returns a read-only slice of all key/value pairs
        pub fn toSlice(self: *const Self) []const Pair {
            return self.mapItems[0..];
        }

        /// return an iterator over keys.
        pub fn keys(self: Self) Iterator([]const u8) {
            const Keys = Iterator([]const u8);
            return Keys.init(self.mapItems[0..]);
        }

        /// return an iterator over values.
        pub fn values(self: Self) Iterator(V) {
            const Values = Iterator(V);
            return Values.init(self.mapItems[0..]);
        }

        /// return an iterator over key/value pairs.
        pub fn items(self: Self) Iterator(Pair) {
            const Items = Iterator(Pair);
            return Items.init(self.mapItems[0..]);
        }

        /// check if a key exists in the map.
        pub fn contains(self: Self, key: []const u8) bool {
            return self.getIndex(key) != null;
        }

        /// number of entries in the map.
        pub fn length(self: Self) usize {
            return self.mapItems.len;
        }

        /// check if the map has no entries.
        pub fn isEmpty(self: Self) bool {
            return self.length() == 0;
        }

        /// return the underlying table capacity.
        pub fn capacity(self: Self) u64 {
            return self.mapCap;
        }

        /// find the bucket index for a key, or null if missing.
        pub fn getIndex(self: Self, key: []const u8) ?usize {
            var i: usize = 0;
            const keyHash: u64 = hashMethod(key);
            const baseIdx = keyHash & (self.mapCap - 1);
            var bucketIdx = baseIdx;
            var foundKey = false;

            const secondHash: u64 = switch (probe) {
                .DoubleHash => zh.cityHash64(key) | 1,
                else => undefined,
            };

            while (i < self.length()) {
                switch (self.mapTable[bucketIdx]) {
                    .Empty => break,
                    .Occupied => |kvPair| {
                        if (eqlMethod(kvPair.key, key)) {
                            foundKey = true;
                            break;
                        }
                        bucketIdx = probeMethod(baseIdx, i, secondHash) & (self.mapCap - 1);
                        i += 1;
                    },
                }
            }

            return if (foundKey) bucketIdx else null;
        }

        /// get the value for a key, or null if not found.
        pub fn get(self: Self, key: []const u8) ?V {
            const idx = self.getIndex(key) orelse return null;
            const bucket = self.mapTable[idx];
            return switch (bucket) {
                .Occupied => |kvPair| kvPair.value,
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
    const mapQ = QMap.init(kv);
    try std.testing.expect(mapQ.get("x") orelse 0 == 100);
    try std.testing.expect(mapQ.get("y") orelse 0 == 200);

    const RMap = ComptimeHashMap(u32, null, Prober.DoubleHash, null);
    const mapR = RMap.init(kv);
    try std.testing.expect(mapR.get("x") orelse 0 == 100);
    try std.testing.expect(mapR.get("y") orelse 0 == 200);
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
    const lenMap = LenMapT.init(kv);

    try std.testing.expect(lenMap.get("zz") orelse 0 == 20);
    try std.testing.expect(lenMap.get("XYZ") orelse 0 == 30);
    try std.testing.expect(lenMap.get("QRSD") == null);
}
