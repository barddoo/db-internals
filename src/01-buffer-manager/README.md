# 01 — Pages, slots, and the buffer pool

A basic page cache with slotted pages. Pages live on disk, the buffer manager
keeps a bounded number of them in memory, and callers pin/unpin pages while
using them.

This is the code for post 1 of the series. The draft is kept locally (same
name, under `src/articles/`, never committed); only this code is published.

## Files

| File                        | What it does                                                                                           |
| --------------------------- | ------------------------------------------------------------------------------------------------------ |
| `slotted_page.zig`          | Page layout: header, slot directory, record data. Insert/read/remove/update/compact.                   |
| `disk_manager.zig`          | `FileDisk`, a file-backed page store with an in-memory free list, plus optional direct I/O.            |
| `frame.zig`                 | The `Frame` struct: page data, page id, atomic pin count, dirty flag, frame latch.                     |
| `buffer_manager.zig`        | `BufferManager(Disk, Policy)`: fixed frame pool, page table, pin/unpin, eviction, dirty flush, guards. |
| `policies/clock_policy.zig` | `ClockPolicy`, the default replacement policy.                                                         |
| `policies/lru_policy.zig`   | `LruPolicy`, an exact LRU alternative for comparison.                                                  |
| `main.zig`                  | Demo: writes pages to `buffer_manager.db`, evicts and reloads them, deletes + compacts.                |

## Slotted page layout

```
+---------------------------------------------------------------+
| header | slot 0 | slot 1 | ... | free space | record data ... |
+---------------------------------------------------------------+
0        8                                   lower -> <- upper  end
```

The 8-byte header:

| Offset | Field        | Meaning                                         |
| ------ | ------------ | ----------------------------------------------- |
| 0      | `slot_count` | number of slots, including deleted ones         |
| 2      | `lower`      | end of the slot directory / start of free space |
| 4      | `upper`      | start of the record data / end of free space    |
| 6      | —            | reserved, zeroed                                |

All header fields are little-endian `u16`. Each slot is 4 bytes:

```zig
pub const Slot = struct {
    offset: u16,   // where the record starts in the page
    length: u16,   // how many bytes it uses
};
```

- **Insert** — take space from the top (`upper -= len`), append a slot at
  `lower`, grow `lower`. Fails with `error.PageFull` when
  `upper - lower < record.len + 4` (the record plus its slot), and with
  `error.RecordTooLarge` above `maxRecordSize()`.
- **Delete** — set the slot's length to 0. The space is reused only by
  `compact`; the slot itself stays as a tombstone.
- **Update** — a same-size or smaller record is overwritten in place. A larger
  one is inserted into a fresh slot and the old slot becomes a **forwarding
  pointer** (`length = 0xFFFF`, `offset = new slot index`), so the caller's
  `(page_id, slot_id)` never changes. `read` and `update` follow exactly one
  hop, so forwards never chain.
- **Compact** — copy live records from a temporary copy back toward the end,
  updating each slot's offset. **Slot numbers do not change.**
- `freeSpace()` is `upper - lower`.

A page is full when `lower == upper`.

## Disk

`FileDisk` stores page `id` at file offset `id * PAGE_SIZE` and implements the
five operations the buffer manager needs:

```zig
allocatePage() !PageId
deletePage(id) !void
readPage(id, *[PAGE_SIZE]u8) !void
writePage(id, *const [PAGE_SIZE]u8) !void
pageCount() PageId
```

Deleted page ids go on an in-memory free list and are reused by the next
`allocatePage`, which zero-fills the page. The free list is **not persisted**:
after a reopen, previously freed ids are simply orphaned.

```zig
var disk = try FileDisk.open(
    allocator,
    io,
    std.Io.Dir.cwd(),
    "buffer_manager.db",
    .{ .truncate = true, .direct = false },  // false: reopen an existing file
);
defer disk.close();
```

`open` recovers `page_count` from the file size, so `.truncate = false`
reopens an existing database. `.direct = true` bypasses the OS page cache
(`F_NOCACHE` on macOS, `O_DIRECT` on Linux), which requires 4096-byte-aligned
buffers on every read and write. The buffer pool does **not** give you that:
`Frame` holds `PAGE_SIZE` bytes of page data plus inline bookkeeping, so
`Frame.data` is only naturally aligned. The demo runs with `.direct = false`;
the flag is exercised at the `FileDisk` level, where test buffers are
explicitly `align(4096)`.

## Buffer manager

`BufferManager(Disk, Policy)` is comptime-checked against the disk and policy
interfaces, and `DefaultPolicy` is `ClockPolicy`:

```zig
var bm = try BufferManager(FileDisk, DefaultPolicy).init(allocator, io, &disk, 3);
defer bm.deinit();
```

- `frames`: a fixed slice of `Frame`.
- `page_table`: `PageId -> *Frame`, guarded by a pool-wide `Mutex`.
- `policy`: replacement state, indexed by frame number.
- Hooks the manager calls: `onHit`, `onLoad`, `onUnpin`, `onRemove`, and
  `pickVictim`.

`fetch(id)`:

- **hit** — `policy.onHit`, increment `pin_count`, return the frame.
- **miss** — take a free frame, or ask the policy for a victim and flush it
  if dirty; `readPage` into the frame; insert into `page_table`; `onLoad`;
  `pin_count = 1`.

If the policy can return no victim, `fetch` returns `error.BufferFull` — the
backpressure that stops one caller from pulling the whole database into RAM.

| Method                                 | Notes                                                              |
| -------------------------------------- | ------------------------------------------------------------------ |
| `newPage() !NewPage`                   | Allocates on disk, loads, resets to an empty slotted page. Pinned. |
| `deletePage(id) !void`                 | Evicts and frees the id. `error.PagePinned` if anyone holds it.    |
| `fetch(id) !*Frame`                    | Pins. Frame latch is *not* taken.                                  |
| `unpin(id, dirty)`                     | Releases a pin; `dirty = true` marks the page for write-back.      |
| `checkedReadPage(id) !ReadPageGuard`   | Pins **and** takes the shared frame latch.                         |
| `checkedWritePage(id) !WritePageGuard` | Pins **and** takes the exclusive frame latch; marks dirty on drop. |
| `flushPage(id)` / `flushAll()`         | Write dirty frames back to disk.                                   |
| `frameCount()` / `residentCount()`     | Pool size / pages currently resident.                              |

Guards must be dropped explicitly:

```zig
var guard = try bm.checkedWritePage(id);
defer guard.drop();
const page = guard.slottedPage();
```

## Usage

```zig
var disk = try FileDisk.open(
    allocator,
    io,
    std.Io.Dir.cwd(),
    "buffer_manager.db",
    .{ .truncate = true },
);
defer disk.close();

var bm = try BufferManager(FileDisk, DefaultPolicy).init(allocator, io, &disk, 3);
defer bm.deinit();

const np = try bm.newPage();          // pinned
const page = np.frame.slottedPage();  // slotted page view
const slot = try page.insert("hello");
_ = slot;
bm.unpin(np.id, true);                // dirty

const frame = try bm.fetch(np.id);    // pinned again
const view = frame.slottedPage();
const record = view.read(0).?;
bm.unpin(np.id, false);
```

## Run

```bash
zig build run-buffer
# or
zig run src/01-buffer-manager/main.zig
```

The demo writes to `buffer_manager.db` in the current directory (truncating it
first) and prints the page count, free space, and file size.

## Tests

```bash
zig build test
```

31 tests. `src/root.zig` references every implementation file so the whole
suite is reached; a file that is exported but never referenced is not
compiled, and its tests silently do not run.

| File                 | Covered                                                                                                                      |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `slotted_page.zig`   | insert/read, remove, shrink and forwarded updates, compact, full page.                                                       |
| `disk_manager.zig`   | file-backed pages, direct I/O.                                                                                               |
| `buffer_manager.zig` | fetch/unpin, dirty eviction + reload, `BufferFull`, `deletePage` and id reuse, read/write guards, persistence across reopen. |
| `policies/*`         | both policies: victim selection, hits, unpin ordering, removal.                                                              |

## Not included yet

- Write-ahead logging / crash recovery. `flushAll` is best-effort ordering,
  not durability.
- Variable-length overflow pages.
- Persisting the free list (freed page ids are lost on reopen).
- Replacement policies beyond clock and LRU (LRU-K, 2Q, ARC).
- Multiple files / a directory layout for a real database.
