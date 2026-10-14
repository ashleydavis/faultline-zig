# Failure types Faultline injects

These are the failures Faultline injects, grouped by what the function is using: memory, files, directories, the network, the clock, random numbers, output, other programs, environment variables and threads. Each failure lists what the failing call returns to your code. Every time Faultline calls a function, it notes each call inside it that can fail. For each of those calls and each failure that applies to it, Faultline calls the function again with only that one failure injected. These calls can reach new calls that can fail and Faultline does the same for them.

## Allocator

| Failure | What the call returns |
| --- | --- |
| Allocation fails | `error.OutOfMemory` from `alloc` |
| Resize fails | the resize reports it cannot grow or shrink in place, so the caller must allocate and copy |
| Remap fails | the remap reports it cannot move, so the caller must allocate and copy |
| Free of a failed allocation | the function under test is still called with the allocator in that state, so cleanup on the error path is exercised |

## File open, create and check

| Failure | What the call returns |
| --- | --- |
| File not found | `error.FileNotFound` |
| Access denied | `error.AccessDenied` |
| Is a directory | `error.IsDir` |
| Not a directory | `error.NotDir` |
| Already exists | `error.PathAlreadyExists` when creating exclusively |
| Name too long | `error.NameTooLong` |
| Symlink loop | `error.SymLinkLoop` |
| Out of space | `error.NoSpaceLeft` |
| Read-only filesystem | `error.ReadOnlyFileSystem` |
| Too many open files | `error.ProcessFdQuotaExceeded` |

## Read

| Failure | What the call returns |
| --- | --- |
| Input or output error | `error.InputOutput` |
| Short read | fewer bytes than asked for, then the rest on the next read |
| Early end of stream | `error.EndOfStream` before the expected length |
| Read of a directory | `error.IsDir` |

## Write

| Failure | What the call returns |
| --- | --- |
| Out of space | `error.NoSpaceLeft` |
| Input or output error | `error.InputOutput` |
| Short write | fewer bytes accepted than offered |
| Quota exceeded | `error.DiskQuota` |
| Read-only filesystem | `error.ReadOnlyFileSystem` |

## Symlink and link operations

| Failure | What the call returns |
| --- | --- |
| Create over an existing path | `error.PathAlreadyExists` |
| Create without permission | `error.AccessDenied` |
| Create in a missing directory | `error.FileNotFound` |
| Out of space | `error.NoSpaceLeft` |
| Read a link that is not a link | `error.NotLink` |
| Read a link that is missing | `error.FileNotFound` |
| Dangling link | a link whose target is not there, so opening it returns `error.FileNotFound` |
| Link loop | a chain of links that returns to itself, so following it returns `error.SymLinkLoop` |
| Remove a link that is missing | `error.FileNotFound` |
| Hard link across filesystems | `error.CrossDevice` |

## Directory listing

| Failure | What the call returns |
| --- | --- |
| Open a missing directory | `error.FileNotFound` |
| Open a file as a directory | `error.NotDir` |
| Access denied | `error.AccessDenied` |
| Error part way through the listing | `error.InputOutput` from a later `next` call, after some entries were returned |
| Empty directory | a listing with no entries |
| Too many open files | `error.ProcessFdQuotaExceeded` |

## Network

| Failure | What the call returns |
| --- | --- |
| Name does not resolve | `error.UnknownHostName` |
| Connection refused | `error.ConnectionRefused` |
| Connection times out | `error.Timeout` |
| Network unreachable | `error.NetworkUnreachable` |
| Connection reset part way through | `error.ConnectionResetByPeer` from a later read or write |
| Short response | the response ends before the expected length |
| Response that does not parse | bytes that are not what the protocol allows |
| Host lookup finds no address | `error.NoAddressReturned` |
| Name server fails | `error.NameServerFailure` |
| Name server returns a bad record | `error.InvalidDnsARecord` |
| Address already in use when listening or binding | `error.AddressInUse` |
| Address not available | `error.AddressUnavailable` |
| Network down | `error.NetworkDown` |
| Host unreachable | `error.HostUnreachable` |
| Connection aborted before it is accepted | `error.ConnectionAborted` |
| Blocked by a firewall | `error.BlockedByFirewall` |
| Message too large to send | `error.MessageOversize` |
| Send on a socket that is not connected | `error.SocketUnconnected` |
| Too many open sockets | `error.ProcessFdQuotaExceeded` |

## Clock

| Failure | What the call returns |
| --- | --- |
| Clock cannot be read | `error.Unexpected` |
| Time goes backwards | a reading earlier than the previous one |
| Time stands still | the same reading on every call |
| Time jumps far forward | a reading far past the previous one |

## Writer

| Failure | What the call returns |
| --- | --- |
| Writer has no room | `error.WriteFailed` on the first write |
| Writer fills part way through | the writes succeed until a fixed number of bytes, then `error.WriteFailed` |
| Short write | fewer bytes accepted than offered |

## Delete

| Failure | What the call returns |
| --- | --- |
| File not found | `error.FileNotFound` |
| Access denied | `error.AccessDenied` |
| File in use | `error.FileBusy` |
| Is a directory | `error.IsDir` |
| Not a directory | `error.NotDir` |
| Directory not empty | `error.DirNotEmpty` |
| Symlink loop | `error.SymLinkLoop` |
| Read-only filesystem | `error.ReadOnlyFileSystem` |
| Error part way through deleting a tree | an error from deleting one entry, after earlier entries were deleted |

## Create a directory

| Failure | What the call returns |
| --- | --- |
| Already exists | `error.PathAlreadyExists` |
| Access denied | `error.AccessDenied` |
| Parent directory missing | `error.FileNotFound` |
| Parent is not a directory | `error.NotDir` |
| Out of space | `error.NoSpaceLeft` |
| Quota exceeded | `error.DiskQuota` |
| Read-only filesystem | `error.ReadOnlyFileSystem` |

## Resolve a path

| Failure | What the call returns |
| --- | --- |
| Path not found | `error.FileNotFound` |
| Not a directory | `error.NotDir` |
| Access denied | `error.AccessDenied` |
| Symlink loop | `error.SymLinkLoop` |
| Name too long | `error.NameTooLong` |

## Standard input, output and error

| Failure | What the call returns |
| --- | --- |
| Input closed | `error.EndOfStream` on the first read |
| Input or output error | `error.InputOutput` |
| Output closed | `error.WriteFailed` |
| Short write | fewer bytes accepted than offered |

## Running another program

| Failure | What the call returns |
| --- | --- |
| Program not found | `error.FileNotFound` |
| Access denied | `error.AccessDenied` |
| Not an executable | `error.InvalidExe` |
| Too many open files | `error.ProcessFdQuotaExceeded` |
| Out of memory | `error.OutOfMemory` |
| Exits with a non-zero code | a result of `.exited` with a non-zero code |
| Killed by a signal | a result of `.signal` |
| Output past the limit | `error.StreamTooLong` |
| Timed out | `error.Timeout` |

## Environment variables

| Failure | What the call returns |
| --- | --- |
| Variable not set | `error.EnvironmentVariableMissing` |
| Variable set to an empty value | an empty string |

## Threads

| Failure | What the call returns |
| --- | --- |
| Too many threads | `error.ThreadQuotaExceeded` |
| Out of resources | `error.SystemResources` |
| Out of memory | `error.OutOfMemory` |
| Locked memory limit reached | `error.LockedMemoryLimitExceeded` |

## Cancellation

An interruption such as a signal reaches a function as a cancelled operation.

| Failure | What the call returns |
| --- | --- |
| Operation cancelled | `error.Canceled` |

## Rename and copy

| Failure | What the call returns |
| --- | --- |
| Source not found | `error.FileNotFound` |
| Access denied | `error.AccessDenied` |
| Destination is a non-empty directory | `error.DirNotEmpty` |
| Destination is a directory | `error.IsDir` |
| File in use | `error.FileBusy` |
| Across filesystems | `error.CrossDevice` |
| Out of space | `error.NoSpaceLeft` |
| Quota exceeded | `error.DiskQuota` |
| Read-only filesystem | `error.ReadOnlyFileSystem` |
| Copy fails part way through | an error from reading or writing, after some bytes were copied |

## Change permissions, owner or timestamps

| Failure | What the call returns |
| --- | --- |
| Access denied | `error.AccessDenied` |
| Not permitted | `error.PermissionDenied` |
| File not found | `error.FileNotFound` |
| Input or output error | `error.InputOutput` |
| Read-only filesystem | `error.ReadOnlyFileSystem` |
| Symlink loop | `error.SymLinkLoop` |

## File length, sync and locks

| Failure | What the call returns |
| --- | --- |
| Length cannot be read | `error.InputOutput` |
| Resize past the size limit | `error.FileTooBig` |
| File cannot be resized | `error.NonResizable` |
| Sync fails | `error.InputOutput` |
| Sync out of space | `error.NoSpaceLeft` |
| Locks not supported | `error.FileLocksUnsupported` |
| Lock out of resources | `error.SystemResources` |
| Lock already held | the try-lock call returns false |
| Read or write at a position on a stream that cannot seek | `error.Unseekable` |
| File not open for reading | `error.NotOpenForReading` |
| Another process holds a lock on the range | `error.LockViolation` |

## Secure random numbers

| Failure | What the call returns |
| --- | --- |
| No entropy available | `error.EntropyUnavailable` |

## Current directory

| Failure | What the call returns |
| --- | --- |
| Current directory was deleted | `error.CurrentDirUnlinked` |
| Path too long | `error.NameTooLong` |
