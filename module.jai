/*
    Import with #import "MyBasic/MyName";
    Name is an interned string identifier. make_name stores one immutable copy of each distinct
    byte string in a shared, thread-safe table. Each Name holds a string descriptor referencing
    that canonical storage; copying a Name does not copy its text. Equality compares data pointers,
    and name_hash hashes the pointer with Knuth multiplication, both independent of text length.
    Matching is case-sensitive and byte-exact, without Unicode normalization.

    Good uses:
    - Repeated asset, animation, event or configuration-defined identifiers used as lookup keys.
    - Names shared by many objects, where deduplication avoids storing repeated copies of text.
    - Interning at loading/input boundaries, then retaining Name values for frequent comparisons
      and hash-table lookups. Name_Table(Value_Type) supplies the key type and callbacks.

    Poor uses:
    - One-off strings, mutable text, chat messages or unbounded unique input: interning adds work,
      and this implementation retains every distinct nonempty string until process exit.
    - Repeatedly converting raw strings in a hot loop: make_name still hashes their contents and
      takes a mutex, even when a nonempty name already exists. Retain the returned Name instead.
    - Audio callbacks or other operations with strict latency limits: make_name may wait on a
      mutex, allocate or grow the table. Copying, comparing and hashing existing Names do not.
    - Persistent or network identifiers: pointer identities and hashes are process-local. Serialize
      the text and intern it again on load. A hash is not a unique identifier; collisions are possible.
    - Closed sets of categories or states: prefer a named enum when the set is known in code.

    Construct through make_name; never modify or free name.text or its bytes. The input only needs
    to stay valid and unchanged during the call. A zero-initialized Name is the empty name.
*/
Name :: struct {
    text: string;
}

// Uses the standard Hash_Table operations. No synchronization is added to individual tables.
// Example: scores: Name_Table(s64); table_add(*scores.table, make_name("player"), 100);
Name_Table :: struct (Value_Type: Type) {
    using table: Table(Name, Value_Type, name_hash, names_equal);
}

operator == :: (a: Name, b: Name) -> bool {
    return names_equal(a, b);
}

/*
    Intern once at input boundaries and retain the Name for subsequent lookups.
    Incoming bytes must remain unchanged for this call.

    Do not call on an audio callback for example:
    Because make_name can lock a mutex and allocate memory:
    - Another thread may hold the mutex, forcing the audio callback to wait.
    - A new name requires copying the string and possibly growing the hash table.
    - The first call also initializes synchronization.
*/
make_name :: (text: string) -> Name {
    result, success := try_make_name(text);
    assert(success, "Could not allocate interned Name storage.");
    return result;
}

/**
 * @brief Interns text with checked string and table allocations.
 * @param[in] text Valid source bytes, borrowed only for this call.
 * @return Canonical Name and success flag. Failure publishes no new name; existing names remain valid.
 * @note Uses the process-lived default allocator, never the caller's temporary allocator.
 */
try_make_name :: (text: string) -> Name, bool {
    if text.count < 0 || (text.count > 0 && text.data == null) {
        return .{}, false;
    }
    if text.count == 0 {
        return .{}, true;
    }

    ensure_name_storage();
    lock(*name_storage.mutex);
    defer unlock(*name_storage.mutex);

    found, canonical := table_find(*name_storage.by_text, text);
    if found {
        return .{canonical}, true;
    }

    // Never inherit a caller's temporary allocator. The default allocator must be process-lived.
    push_allocator(context.default_allocator);
    if !try_grow_name_table() {
        return .{}, false;
    }

    copied: bool;
    canonical, copied = try_copy_string(text);
    if !copied {
        return .{}, false;
    }
    table_add(*name_storage.by_text, canonical, canonical);
    return .{canonical}, true;
}

name_hash :: (name: Name) -> u32 {
    // Knuth multiplicative hashing: retain high bits, not aligned pointer low bits.
    return cast(u32) (knuth_hash(cast(u64) name.text.data) >> 32);
}

names_equal :: (a: Name, b: Name) -> bool {
    return a.text.data == b.text.data;
}

#scope_file
#import "Basic";
#import "MyBasic";
#import "Hash";
#import "Hash_Table";
#import "Thread";
#import "Atomics";

Name_Storage_Status :: enum u32 {
    Uninitialized;
    Initializing;
    Ready;
}

Name_Storage :: struct {
    status: Name_Storage_Status;
    mutex: Mutex;
    by_text: Table(string, string);
}

name_storage: Name_Storage;

try_grow_name_table :: () -> bool {
    table := *name_storage.by_text;
    if (table.slots_filled + 1) * 100 < table.allocated * table.LOAD_FACTOR_PERCENT {
        return true;
    }

    replacement: Table(string, string);
    replacement.allocator = table.allocator;
    if replacement.allocator.proc == null {
        replacement.allocator = context.default_allocator;
    }

    // This private table has no removals: doubling leaves room for every old entry and the new name.
    Entry :: Table(string, string).Entry;
    MAX_CAPACITY :: #run 0x7fffffffffffffff / max(size_of(Entry), 100);
    capacity := table.allocated;
    if capacity == 0 {
        capacity = table.SIZE_MIN;
    }
    else {
        if capacity > MAX_CAPACITY / 2 {
            return false;
        }
        capacity *= 2;
    }

    bytes := capacity * size_of(Entry);
    entries := cast(*Entry)alloc(bytes,, replacement.allocator);
    if entries == null {
        return false;
    }

    memset(entries, 0, bytes);
    replacement.entries.data = entries;
    replacement.entries.count = capacity;
    replacement.allocated = capacity;
    for entry: table.entries {
        if entry.hash >= FIRST_VALID_HASH {
            table_add(*replacement, entry.key, entry.value);
        }
    }

    deinit(table);
    table.* = replacement;
    return true;
}

ensure_name_storage :: () {
    if compare_and_swap(*name_storage.status, .Uninitialized, .Initializing) {
        init(*name_storage.mutex);
        atomic_swap(*name_storage.status, .Ready);
        return;
    }

    // CAS supplies synchronization even where the standard atomic_read is just a plain load.
    while !compare_and_swap(*name_storage.status, .Ready, .Ready) {
        sleep_milliseconds(0);
    }
}
