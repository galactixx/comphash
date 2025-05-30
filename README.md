<p align="center">
  <img src="/docs/logo.png" alt="comptime-hashmap logo" width="75%"/>
</p>

**comphash** is a very lightweight Zig package offering a zero-cost compile-time hash map for immutable, O(1) string-keyed lookups without any runtime allocations.

Perfect for command‑line flag tables, protocol constant look‑ups, compile‑time DSLs, and any situation where the set of keys is known ahead of time.

---

## ✨ **Features**

| Category                | Details                                                                                                            |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Lookup                  | O(1) expected access.                                                                                              |
| **Hash Algorithms**     | Use any `fn([]const u8) u64` — the default is **xxHash64** from [`zighash`](https://github.com/galactixx/zighash). |
| **Probing**             | `Prober` enum: `Linear`, `DoubleHash`, `Bidirectional`, `Triangular`.                                              |
| **Iterators**           | Type‑driven `keys()`, `values()`, `items()`—all lazy and allocation‑free.                                          |
| **No Deps**             | Pure Zig, no libc, no external libs.                                                                               |
| **Allocation**          | No runtime allocations or pointer chasing.                                                                         |
| **Comprehensive Tests** | Built‑in `std.testing` ensures correctness across probing strategies.                                              |

---

## 🚀 **Getting Started**

### Fetch via `zig fetch`

```bash
zig fetch --save git+https://github.com/galactixx/comphash#v0.1.0
```

> This adds a `comphash` entry under `.dependencies` in your `build.zig.zon`.

Then in your build.zig:

```zig
const comphash_mod = b.dependency("comphash", .{
    .target = target,
    .optimize = optimize,
}).module("comphash");

// add to library
lib_mod.addImport("comphash", comphash_mod);

// add to executable
exe.root_module.addImport("comphash", comphash_mod);
```

This lets you `const ch = @import("comphash");` in your Zig code.

## 📚 **Usage**

```zig
const std = @import("std");
const ch = @import("comphash");

const FruitMap = ch.ComptimeHashMap(u32, null, null, null);

pub fn main() !void {
    const kv = &.{ .{ "apple", 10 }, .{ "banana", 20 }, .{ "cherry", 30 } };
    const map = FruitMap.init(kv);

    std.debug.print("apple → {}\n", .{map.get("apple") orelse 0});
    std.debug.print("Length: {}\n",  .{map.length()});
}
```

---

## 🔍 **API**

### `ComptimeHashMap`

```zig
pub fn ComptimeHashMap(
    comptime V:      type,                          // value type
    comptime hasher: ?fn([]const u8) u64,           // optional hash func
    comptime prober: ?Prober,                       // optional probe strategy
    comptime eql:    ?fn([]const u8,[]const u8)bool // optional equality
) type
```

Calling this generic returns **a new struct type** with the following notable members:

| Method                            | Description                                                              |
| --------------------------------- | ------------------------------------------------------------------------ |
| `init(kvs)`                       | Build the table at comptime. Accepts `[]const struct { []const u8, V }`. |
| `get(key)`                        | Returns `?V`.                                                            |
| `contains(key)`                   | Boolean containment check.                                               |
| `length()` / `isEmpty()`          | Item count helpers.                                                      |
| `keys()` / `values()` / `items()` | Lazy iterators.                                                          |
| `capacity()`                      | Underlying table size (power‑of‑two).                                    |

### `Prober`

Enum controlling collision resolution:

* `Linear` – `base + i`
* `DoubleHash` – `base + i * (h(key) | 1)`
* `Bidirectional` – Alternates ±offsets
* `Triangular` – `base + i * (i + 1) / 2`

Select with the third parameter to `ComptimeHashMap`.

---

## 🤝 **License**

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

---

## 📞 **Contact & Contributing**

Feel free to open an [issue](https://github.com/galactixx/comphash/issues) or a pull request.  Discussion and feedback are welcome!
