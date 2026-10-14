// Every failure Faultline injects, grouped by the effect a function uses. This is the table in
// `docs/FAILURES.md` as code: a test compares the two, so a row cannot be added to one and left out
// of the other.
//
// An id is what a replay token names a failure as. It never changes once a replay token may carry
// it, so a row is renamed here only together with a change to what reads the token.

const point = @import("point.zig");

// One way a call can fail.
pub const Kind = struct {
    // What a replay token names this failure as.
    id: []const u8,

    // The "Failure" column of the table: what goes wrong.
    description: []const u8,

    // The "What the call returns" column of the table, with the code formatting removed.
    returns: []const u8,
};

// The "Allocator" group of the table.
pub const allocator_kinds = [_]Kind{
    .{ .id = "allocation_fails", .description = "Allocation fails", .returns = "error.OutOfMemory from alloc" },
    .{ .id = "resize_fails", .description = "Resize fails", .returns = "the resize reports it cannot grow or shrink in place, so the caller must allocate and copy" },
    .{ .id = "remap_fails", .description = "Remap fails", .returns = "the remap reports it cannot move, so the caller must allocate and copy" },
    .{ .id = "free_of_a_failed_allocation", .description = "Free of a failed allocation", .returns = "the function under test is still called with the allocator in that state, so cleanup on the error path is exercised" },
};

// The "File open, create and check" group of the table.
pub const file_open_kinds = [_]Kind{
    .{ .id = "file_not_found", .description = "File not found", .returns = "error.FileNotFound" },
    .{ .id = "access_denied", .description = "Access denied", .returns = "error.AccessDenied" },
    .{ .id = "is_a_directory", .description = "Is a directory", .returns = "error.IsDir" },
    .{ .id = "not_a_directory", .description = "Not a directory", .returns = "error.NotDir" },
    .{ .id = "already_exists", .description = "Already exists", .returns = "error.PathAlreadyExists when creating exclusively" },
    .{ .id = "name_too_long", .description = "Name too long", .returns = "error.NameTooLong" },
    .{ .id = "symlink_loop", .description = "Symlink loop", .returns = "error.SymLinkLoop" },
    .{ .id = "out_of_space", .description = "Out of space", .returns = "error.NoSpaceLeft" },
    .{ .id = "read_only_filesystem", .description = "Read-only filesystem", .returns = "error.ReadOnlyFileSystem" },
    .{ .id = "too_many_open_files", .description = "Too many open files", .returns = "error.ProcessFdQuotaExceeded" },
};

// The "Read" group of the table.
pub const read_kinds = [_]Kind{
    .{ .id = "input_or_output_error", .description = "Input or output error", .returns = "error.InputOutput" },
    .{ .id = "short_read", .description = "Short read", .returns = "fewer bytes than asked for, then the rest on the next read" },
    .{ .id = "early_end_of_stream", .description = "Early end of stream", .returns = "error.EndOfStream before the expected length" },
    .{ .id = "read_of_a_directory", .description = "Read of a directory", .returns = "error.IsDir" },
};

// The "Write" group of the table.
pub const write_kinds = [_]Kind{
    .{ .id = "out_of_space", .description = "Out of space", .returns = "error.NoSpaceLeft" },
    .{ .id = "input_or_output_error", .description = "Input or output error", .returns = "error.InputOutput" },
    .{ .id = "short_write", .description = "Short write", .returns = "fewer bytes accepted than offered" },
    .{ .id = "quota_exceeded", .description = "Quota exceeded", .returns = "error.DiskQuota" },
    .{ .id = "read_only_filesystem", .description = "Read-only filesystem", .returns = "error.ReadOnlyFileSystem" },
};

// The "Symlink and link operations" group of the table.
pub const link_kinds = [_]Kind{
    .{ .id = "create_over_an_existing_path", .description = "Create over an existing path", .returns = "error.PathAlreadyExists" },
    .{ .id = "create_without_permission", .description = "Create without permission", .returns = "error.AccessDenied" },
    .{ .id = "create_in_a_missing_directory", .description = "Create in a missing directory", .returns = "error.FileNotFound" },
    .{ .id = "out_of_space", .description = "Out of space", .returns = "error.NoSpaceLeft" },
    .{ .id = "read_a_link_that_is_not_a_link", .description = "Read a link that is not a link", .returns = "error.NotLink" },
    .{ .id = "read_a_link_that_is_missing", .description = "Read a link that is missing", .returns = "error.FileNotFound" },
    .{ .id = "dangling_link", .description = "Dangling link", .returns = "a link whose target is not there, so opening it returns error.FileNotFound" },
    .{ .id = "link_loop", .description = "Link loop", .returns = "a chain of links that returns to itself, so following it returns error.SymLinkLoop" },
    .{ .id = "remove_a_link_that_is_missing", .description = "Remove a link that is missing", .returns = "error.FileNotFound" },
    .{ .id = "hard_link_across_filesystems", .description = "Hard link across filesystems", .returns = "error.CrossDevice" },
};

// The "Directory listing" group of the table.
pub const directory_listing_kinds = [_]Kind{
    .{ .id = "open_a_missing_directory", .description = "Open a missing directory", .returns = "error.FileNotFound" },
    .{ .id = "open_a_file_as_a_directory", .description = "Open a file as a directory", .returns = "error.NotDir" },
    .{ .id = "access_denied", .description = "Access denied", .returns = "error.AccessDenied" },
    .{ .id = "error_part_way_through_the_listing", .description = "Error part way through the listing", .returns = "error.InputOutput from a later next call, after some entries were returned" },
    .{ .id = "empty_directory", .description = "Empty directory", .returns = "a listing with no entries" },
    .{ .id = "too_many_open_files", .description = "Too many open files", .returns = "error.ProcessFdQuotaExceeded" },
};

// The "Network" group of the table.
pub const network_kinds = [_]Kind{
    .{ .id = "name_does_not_resolve", .description = "Name does not resolve", .returns = "error.UnknownHostName" },
    .{ .id = "connection_refused", .description = "Connection refused", .returns = "error.ConnectionRefused" },
    .{ .id = "connection_times_out", .description = "Connection times out", .returns = "error.Timeout" },
    .{ .id = "network_unreachable", .description = "Network unreachable", .returns = "error.NetworkUnreachable" },
    .{ .id = "connection_reset_part_way_through", .description = "Connection reset part way through", .returns = "error.ConnectionResetByPeer from a later read or write" },
    .{ .id = "short_response", .description = "Short response", .returns = "the response ends before the expected length" },
    .{ .id = "response_that_does_not_parse", .description = "Response that does not parse", .returns = "bytes that are not what the protocol allows" },
    .{ .id = "host_lookup_finds_no_address", .description = "Host lookup finds no address", .returns = "error.NoAddressReturned" },
    .{ .id = "name_server_fails", .description = "Name server fails", .returns = "error.NameServerFailure" },
    .{ .id = "name_server_returns_a_bad_record", .description = "Name server returns a bad record", .returns = "error.InvalidDnsARecord" },
    .{ .id = "address_already_in_use_when_listening_or_binding", .description = "Address already in use when listening or binding", .returns = "error.AddressInUse" },
    .{ .id = "address_not_available", .description = "Address not available", .returns = "error.AddressUnavailable" },
    .{ .id = "network_down", .description = "Network down", .returns = "error.NetworkDown" },
    .{ .id = "host_unreachable", .description = "Host unreachable", .returns = "error.HostUnreachable" },
    .{ .id = "connection_aborted_before_it_is_accepted", .description = "Connection aborted before it is accepted", .returns = "error.ConnectionAborted" },
    .{ .id = "blocked_by_a_firewall", .description = "Blocked by a firewall", .returns = "error.BlockedByFirewall" },
    .{ .id = "message_too_large_to_send", .description = "Message too large to send", .returns = "error.MessageOversize" },
    .{ .id = "send_on_a_socket_that_is_not_connected", .description = "Send on a socket that is not connected", .returns = "error.SocketUnconnected" },
    .{ .id = "too_many_open_sockets", .description = "Too many open sockets", .returns = "error.ProcessFdQuotaExceeded" },
};

// The "Clock" group of the table.
pub const clock_kinds = [_]Kind{
    .{ .id = "clock_cannot_be_read", .description = "Clock cannot be read", .returns = "error.Unexpected" },
    .{ .id = "time_goes_backwards", .description = "Time goes backwards", .returns = "a reading earlier than the previous one" },
    .{ .id = "time_stands_still", .description = "Time stands still", .returns = "the same reading on every call" },
    .{ .id = "time_jumps_far_forward", .description = "Time jumps far forward", .returns = "a reading far past the previous one" },
};

// The "Writer" group of the table.
pub const writer_kinds = [_]Kind{
    .{ .id = "writer_has_no_room", .description = "Writer has no room", .returns = "error.WriteFailed on the first write" },
    .{ .id = "writer_fills_part_way_through", .description = "Writer fills part way through", .returns = "the writes succeed until a fixed number of bytes, then error.WriteFailed" },
    .{ .id = "short_write", .description = "Short write", .returns = "fewer bytes accepted than offered" },
};

// The "Delete" group of the table.
pub const delete_kinds = [_]Kind{
    .{ .id = "file_not_found", .description = "File not found", .returns = "error.FileNotFound" },
    .{ .id = "access_denied", .description = "Access denied", .returns = "error.AccessDenied" },
    .{ .id = "file_in_use", .description = "File in use", .returns = "error.FileBusy" },
    .{ .id = "is_a_directory", .description = "Is a directory", .returns = "error.IsDir" },
    .{ .id = "not_a_directory", .description = "Not a directory", .returns = "error.NotDir" },
    .{ .id = "directory_not_empty", .description = "Directory not empty", .returns = "error.DirNotEmpty" },
    .{ .id = "symlink_loop", .description = "Symlink loop", .returns = "error.SymLinkLoop" },
    .{ .id = "read_only_filesystem", .description = "Read-only filesystem", .returns = "error.ReadOnlyFileSystem" },
    .{ .id = "error_part_way_through_deleting_a_tree", .description = "Error part way through deleting a tree", .returns = "an error from deleting one entry, after earlier entries were deleted" },
};

// The "Create a directory" group of the table.
pub const make_directory_kinds = [_]Kind{
    .{ .id = "already_exists", .description = "Already exists", .returns = "error.PathAlreadyExists" },
    .{ .id = "access_denied", .description = "Access denied", .returns = "error.AccessDenied" },
    .{ .id = "parent_directory_missing", .description = "Parent directory missing", .returns = "error.FileNotFound" },
    .{ .id = "parent_is_not_a_directory", .description = "Parent is not a directory", .returns = "error.NotDir" },
    .{ .id = "out_of_space", .description = "Out of space", .returns = "error.NoSpaceLeft" },
    .{ .id = "quota_exceeded", .description = "Quota exceeded", .returns = "error.DiskQuota" },
    .{ .id = "read_only_filesystem", .description = "Read-only filesystem", .returns = "error.ReadOnlyFileSystem" },
};

// The "Resolve a path" group of the table.
pub const resolve_path_kinds = [_]Kind{
    .{ .id = "path_not_found", .description = "Path not found", .returns = "error.FileNotFound" },
    .{ .id = "not_a_directory", .description = "Not a directory", .returns = "error.NotDir" },
    .{ .id = "access_denied", .description = "Access denied", .returns = "error.AccessDenied" },
    .{ .id = "symlink_loop", .description = "Symlink loop", .returns = "error.SymLinkLoop" },
    .{ .id = "name_too_long", .description = "Name too long", .returns = "error.NameTooLong" },
};

// The "Standard input, output and error" group of the table.
pub const standard_stream_kinds = [_]Kind{
    .{ .id = "input_closed", .description = "Input closed", .returns = "error.EndOfStream on the first read" },
    .{ .id = "input_or_output_error", .description = "Input or output error", .returns = "error.InputOutput" },
    .{ .id = "output_closed", .description = "Output closed", .returns = "error.WriteFailed" },
    .{ .id = "short_write", .description = "Short write", .returns = "fewer bytes accepted than offered" },
};

// The "Running another program" group of the table.
pub const spawn_kinds = [_]Kind{
    .{ .id = "program_not_found", .description = "Program not found", .returns = "error.FileNotFound" },
    .{ .id = "access_denied", .description = "Access denied", .returns = "error.AccessDenied" },
    .{ .id = "not_an_executable", .description = "Not an executable", .returns = "error.InvalidExe" },
    .{ .id = "too_many_open_files", .description = "Too many open files", .returns = "error.ProcessFdQuotaExceeded" },
    .{ .id = "out_of_memory", .description = "Out of memory", .returns = "error.OutOfMemory" },
    .{ .id = "exits_with_a_non_zero_code", .description = "Exits with a non-zero code", .returns = "a result of .exited with a non-zero code" },
    .{ .id = "killed_by_a_signal", .description = "Killed by a signal", .returns = "a result of .signal" },
    .{ .id = "output_past_the_limit", .description = "Output past the limit", .returns = "error.StreamTooLong" },
    .{ .id = "timed_out", .description = "Timed out", .returns = "error.Timeout" },
};

// The "Environment variables" group of the table.
pub const environment_kinds = [_]Kind{
    .{ .id = "variable_not_set", .description = "Variable not set", .returns = "error.EnvironmentVariableMissing" },
    .{ .id = "variable_set_to_an_empty_value", .description = "Variable set to an empty value", .returns = "an empty string" },
};

// The "Threads" group of the table.
pub const thread_kinds = [_]Kind{
    .{ .id = "too_many_threads", .description = "Too many threads", .returns = "error.ThreadQuotaExceeded" },
    .{ .id = "out_of_resources", .description = "Out of resources", .returns = "error.SystemResources" },
    .{ .id = "out_of_memory", .description = "Out of memory", .returns = "error.OutOfMemory" },
    .{ .id = "locked_memory_limit_reached", .description = "Locked memory limit reached", .returns = "error.LockedMemoryLimitExceeded" },
};

// The "Cancellation" group of the table.
pub const cancellation_kinds = [_]Kind{
    .{ .id = "operation_cancelled", .description = "Operation cancelled", .returns = "error.Canceled" },
};

// The "Rename and copy" group of the table.
pub const rename_copy_kinds = [_]Kind{
    .{ .id = "source_not_found", .description = "Source not found", .returns = "error.FileNotFound" },
    .{ .id = "access_denied", .description = "Access denied", .returns = "error.AccessDenied" },
    .{ .id = "destination_is_a_non_empty_directory", .description = "Destination is a non-empty directory", .returns = "error.DirNotEmpty" },
    .{ .id = "destination_is_a_directory", .description = "Destination is a directory", .returns = "error.IsDir" },
    .{ .id = "file_in_use", .description = "File in use", .returns = "error.FileBusy" },
    .{ .id = "across_filesystems", .description = "Across filesystems", .returns = "error.CrossDevice" },
    .{ .id = "out_of_space", .description = "Out of space", .returns = "error.NoSpaceLeft" },
    .{ .id = "quota_exceeded", .description = "Quota exceeded", .returns = "error.DiskQuota" },
    .{ .id = "read_only_filesystem", .description = "Read-only filesystem", .returns = "error.ReadOnlyFileSystem" },
    .{ .id = "copy_fails_part_way_through", .description = "Copy fails part way through", .returns = "an error from reading or writing, after some bytes were copied" },
};

// The "Change permissions, owner or timestamps" group of the table.
pub const attributes_kinds = [_]Kind{
    .{ .id = "access_denied", .description = "Access denied", .returns = "error.AccessDenied" },
    .{ .id = "not_permitted", .description = "Not permitted", .returns = "error.PermissionDenied" },
    .{ .id = "file_not_found", .description = "File not found", .returns = "error.FileNotFound" },
    .{ .id = "input_or_output_error", .description = "Input or output error", .returns = "error.InputOutput" },
    .{ .id = "read_only_filesystem", .description = "Read-only filesystem", .returns = "error.ReadOnlyFileSystem" },
    .{ .id = "symlink_loop", .description = "Symlink loop", .returns = "error.SymLinkLoop" },
};

// The "File length, sync and locks" group of the table.
pub const file_state_kinds = [_]Kind{
    .{ .id = "length_cannot_be_read", .description = "Length cannot be read", .returns = "error.InputOutput" },
    .{ .id = "resize_past_the_size_limit", .description = "Resize past the size limit", .returns = "error.FileTooBig" },
    .{ .id = "file_cannot_be_resized", .description = "File cannot be resized", .returns = "error.NonResizable" },
    .{ .id = "sync_fails", .description = "Sync fails", .returns = "error.InputOutput" },
    .{ .id = "sync_out_of_space", .description = "Sync out of space", .returns = "error.NoSpaceLeft" },
    .{ .id = "locks_not_supported", .description = "Locks not supported", .returns = "error.FileLocksUnsupported" },
    .{ .id = "lock_out_of_resources", .description = "Lock out of resources", .returns = "error.SystemResources" },
    .{ .id = "lock_already_held", .description = "Lock already held", .returns = "the try-lock call returns false" },
    .{ .id = "read_or_write_at_a_position_on_a_stream_that_cannot_seek", .description = "Read or write at a position on a stream that cannot seek", .returns = "error.Unseekable" },
    .{ .id = "file_not_open_for_reading", .description = "File not open for reading", .returns = "error.NotOpenForReading" },
    .{ .id = "another_process_holds_a_lock_on_the_range", .description = "Another process holds a lock on the range", .returns = "error.LockViolation" },
};

// The "Secure random numbers" group of the table.
pub const random_kinds = [_]Kind{
    .{ .id = "no_entropy_available", .description = "No entropy available", .returns = "error.EntropyUnavailable" },
};

// The "Current directory" group of the table.
pub const current_directory_kinds = [_]Kind{
    .{ .id = "current_directory_was_deleted", .description = "Current directory was deleted", .returns = "error.CurrentDirUnlinked" },
    .{ .id = "path_too_long", .description = "Path too long", .returns = "error.NameTooLong" },
};

// The failures that can happen to a call in `effect`.
pub fn kindsOf(effect: point.Effect) []const Kind {
    return switch (effect) {
        .allocator => &allocator_kinds,
        .file_open => &file_open_kinds,
        .read => &read_kinds,
        .write => &write_kinds,
        .link => &link_kinds,
        .directory_listing => &directory_listing_kinds,
        .network => &network_kinds,
        .clock => &clock_kinds,
        .writer => &writer_kinds,
        .delete => &delete_kinds,
        .make_directory => &make_directory_kinds,
        .resolve_path => &resolve_path_kinds,
        .standard_stream => &standard_stream_kinds,
        .spawn => &spawn_kinds,
        .environment => &environment_kinds,
        .thread => &thread_kinds,
        .cancellation => &cancellation_kinds,
        .rename_copy => &rename_copy_kinds,
        .attributes => &attributes_kinds,
        .file_state => &file_state_kinds,
        .random => &random_kinds,
        .current_directory => &current_directory_kinds,
    };
}

test {
    _ = @import("failures.test.zig");
}
