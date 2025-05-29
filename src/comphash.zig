const std = @import("std");
const zh = @import("zighash");

pub const Prober = enum {
    Linear,
    Quadratic,
    PseudoRandom,
    Bidirectional,
    Triangular,
};

/// a simple split-mix integer hash used for pseudo-random probing.
fn splitMix64(base: u64, i: u64) u64 {
    var z = base ^ i;
    z +%= 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    const rand_i = z ^ (z >> 31);
    return base +% rand_i;
}

/// returns the probing function for the given Prober strategy.
fn getProber(prober: Prober) fn (base: u64, i: u64) u64 {
    return switch (prober) {
        Prober.Linear => struct {
            /// linear probing: next = base + i
            pub fn function(base: u64, i: u64) u64 {
                return base +% i;
            }
        }.function,
        Prober.Quadratic => struct {
            /// quadratic probing: next = base + (1 << i)
            pub fn function(base: u64, i: u64) u64 {
                return base +% (1 << i);
            }
        }.function,
        Prober.PseudoRandom => struct {
            /// pseudo-random probing via splitMix64
            pub fn function(base: u64, i: u64) u64 {
                return splitMix64(base, i);
            }
        }.function,
        Prober.Bidirectional => struct {
            /// bidirectional probing: alternates forward/backward offsets
            pub fn function(base: u64, i: u64) u64 {
                const half = i / 2;
                const offset: i64 = @intCast(if ((i & 1) == 1) half + 1 else -half);
                const baseSigned: i64 = @intCast(base);
                return @intCast(baseSigned + offset);
            }
        }.function,
        Prober.Triangular => struct {
            /// triangular probing: next = base + (i*(i+1)/2)
            pub fn function(base: u64, i: u64) u64 {
                const offset = (i * (i + 1)) / 2;
                return base + offset;
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

/// generates a compile-time hash map type for key/value pairs known at comptime.
pub fn ComptimeHashMap(
    comptime V: type,
    comptime kvPairs: []const struct { []const u8, V },
    hasher: ?fn ([]const u8) u64,
    prober: ?Prober,
    eql: ?fn ([]const u8, []const u8) bool,
) type {
    const hashMethod = hasher orelse defaultHasher;
    const probe = prober orelse Prober.Linear;
    const probeMethod = getProber(probe);
    const eqlMethod = eql orelse defaultEql;

    const Pair = struct { key: []const u8, value: V };

    const KVPair = union(enum) {
        Empty,
        Deleted,
        Occupied: Pair,
    };

    const M = try std.math.ceilPowerOfTwo(usize, kvPairs.len * 2);

    return struct {
        const Self = @This();

        hasher: fn ([]const u8) u64,
        prober: fn (base: u64, i: u64) u64,
        eqler: fn ([]const u8, []const u8) bool,
        mapTable: [M]KVPair,
        mapItems: [kvPairs.len]Pair,

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
        pub fn init() Self {
            var mapItems: [kvPairs.len]Pair = undefined;
            var mapTable: [M]KVPair = [_]KVPair{KVPair.Empty} ** M;

            for (kvPairs, 0..) |kvPair, idx| {
                const computedHash = hashMethod(kvPair[0]);
                const baseIndex = computedHash & (M - 1);
                var i: u64 = 0;
                var bucketIdx: u64 = baseIndex;

                // Probe until an empty slot is found
                while (!(mapTable[bucketIdx] == KVPair.Empty)) : (i += 1) {
                    bucketIdx = probeMethod(baseIndex, i) & (M - 1);
                }

                const pair = Pair{ .key = kvPair[0], .value = kvPair[1] };
                mapTable[bucketIdx] = KVPair{ .Occupied = pair };
                mapItems[idx] = pair;
            }

            return Self{
                .hasher = hashMethod,
                .prober = probeMethod,
                .eqler = eqlMethod,
                .mapTable = mapTable,
                .mapItems = mapItems,
            };
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
        pub fn capacity(_: Self) usize {
            return M;
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

        /// find the bucket index for a key, or null if missing.
        pub fn getIndex(self: Self, key: []const u8) ?usize {
            var bucketsSeen: usize = 0;
            const keyHash: u64 = hashMethod(key);
            var bucketIdx = keyHash & (M - 1);
            var i: usize = 0;

            while (bucketsSeen != M and
                switch (self.mapTable[bucketIdx]) {
                    .Empty => false,
                    .Occupied => |kvPair| !eqlMethod(kvPair.key, key),
                    else => true,
                }) : (i += 1)
            {
                bucketIdx = probeMethod(bucketIdx, i) & (M - 1);
                bucketsSeen += 1;
            }

            return if (bucketsSeen != M) bucketIdx else null;
        }

        /// get the value for a key, or null if not found.
        pub fn get(self: Self, key: []const u8) ?V {
            const idx = self.getIndex(key) orelse return null;
            const bucket = self.mapTable[idx];
            return bucket.Occupied.value;
        }
    };
}
