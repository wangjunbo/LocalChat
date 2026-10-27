# Folder transfer v1

Both clients advertise `supportsFolders: true` in `hello`. Never send a directory offer to a peer without this capability. Ordinary file packets remain unchanged.

1. `offer`: existing transfer ID, root `name`, `isDirectory: true`, `entryCount` (all descendants, including empty directories), `size` (sum of raw file bytes), and `sentAt`. The root itself is not an entry.
2. Receiver creates a unique staging directory and replies `accept`.
3. Sender walks parents before children. For each descendant it sends `entry` with the same transfer ID, relative `name` using `/`, `isDirectory` boolean, and `size` (zero for a directory). Each file entry is followed immediately by its ordinary base64 `chunk` packets, totaling exactly that entry's size. Empty files need only their entry. No archive/container or compression is used.
4. `end` is valid only after the declared number of entries and all declared file bytes have arrived. Receiver publishes the completed root under a collision-free name and replies `complete`. An empty root is `entryCount: 0, size: 0`, followed by `end`.

Progress counts raw file bytes across the root. Directory entries refresh the transfer inactivity timer. Existing `progress`, `reject`, timeout, disconnect and receipt behavior apply to the whole directory. Failure cleans the staging tree; incomplete trees are never published as complete. A repeated offer for a saved transfer repeats `complete` without creating another copy.

Paths must be relative, nonempty, at most 4096 UTF-8 bytes and 128 components. Reject empty, `.` and `..` components, backslashes, C0/C1 control characters, absolute paths, duplicates, missing parents and file/directory conflicts. Never create or follow symlinks from the stream. Files and directories only; symbolic links and special files in a source tree are unsupported. At most 100,000 entries and 9,007,199,254,740,991 raw bytes. All counts are nonnegative integers; each entry must fit the remaining advertised byte count.

Offline queues persist a directory copy plus its root type; reconnect regenerates the entry plan and negotiates capability before offering. Old clients leave the directory pending with an upgrade message. Retrying restarts the entire tree; no ZIP fallback or partial resume. File permissions, extended attributes and other platform metadata are not transferred.
