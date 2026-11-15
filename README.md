# db-internals

Code for the **Database Internals** series, published at
[charlesfonseca.substack.com](https://charlesfonseca.substack.com/).
A series on how databases actually work, from the page up.

Every post is backed by working code here. Each topic has its own
`zig build run-*` step, so you can reproduce the numbers in the post instead of
taking my word for them.

## Posts

| #   | Post                                        | Code                                               | Demo                   |
| --- | ------------------------------------------- | -------------------------------------------------- | ---------------------- |
| 1   | Pages, slots, and the buffer pool — *draft* | [`src/01-buffer-manager/`](src/01-buffer-manager/) | `zig build run-buffer` |

New posts land at [charlesfonseca.substack.com](https://charlesfonseca.substack.com/);
this table gets the post URL once it is published.

Post 1 walks through the page format (header, slot directory, forwarding
pointers) and then the buffer pool: frames, the page table, pinning, clock
replacement, and write-back.

### Planned

| #   | Post                         | Code               |
| --- | ---------------------------- | ------------------ |
| 2   | B-trees                      | `src/02-btree/`    |
| 3   | The executor                 | `src/03-executor/` |
| 4   | LSM trees                    | `src/04-lsm/`      |
| 5   | MVCC                         | `src/05-mvcc/`     |
| 6   | Durability: WAL and recovery | `src/06-wal/`      |
| 7   | Query planning               | `src/07-planner/`  |

The code is the only thing this repo publishes. Drafts live locally, next to
the code but outside version control (`src/articles/`, gitignored), and the
published copy lives on Substack.

## Layout

```
db-internals/
├── build.zig
├── build.zig.zon
└── src/
    ├── root.zig                     # module root; imports every article dir
    └── 01-buffer-manager/
        ├── slotted_page.zig         # page format: header, slots, records
        ├── disk_manager.zig         # FileDisk: file-backed page store
        ├── frame.zig                # Frame: data, page id, pin count, dirty, latch
        ├── buffer_manager.zig       # frames, page table, pin/unpin, replacement
        ├── policies/
        │   ├── clock_policy.zig     # default replacement policy
        │   └── lru_policy.zig       # exact LRU, for comparison
        ├── main.zig                 # demo
        └── README.md                # implementation notes
```

## Running

```bash
git clone https://github.com/barddoo/db-internals
cd db-internals

zig build test        # run the test suite (31 tests)
zig build run-buffer  # run the buffer pool demo
```

Requires Zig 0.17.

## Conventions

- **One post, one directory.** `src/01-buffer-manager/` holds the code and its
  implementation notes; the draft is kept locally under `src/articles/` with
  the same name and is never committed.
- **Numbers are append-only.** A post written later always takes the next
  number, and existing directories are never renamed or renumbered. Published
  posts link to pinned commits, so moving a path breaks live links.
- **The tests are the contract.** `src/root.zig` imports every implementation
  file; a `pub const` alone is not enough, because Zig does not compile
  declarations that nothing references, and their tests silently don't run.
- **Every post has a runnable demo** that prints the numbers quoted in the
  prose.
- Build steps are named after the concept (`run-buffer`), not the post number.
