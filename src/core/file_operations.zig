//! Non-replacing tree operations must fail safely on unsupported filesystems.
const std = @import("std");

pub fn renamePreserve(old_dir: std.Io.Dir, old_path: []const u8, new_dir: std.Io.Dir, new_path: []const u8, io: std.Io) !void {
    if (@import("builtin").os.tag != .linux) return std.Io.Dir.renamePreserve(old_dir, old_path, new_dir, new_path, io);
    // Zig 0.16 treats EINVAL here as a programming error. Linux also returns it
    // for filesystems without RENAME_NOREPLACE (including this WSL /mnt/c).
    // Never emulate this using an existence check followed by replacing rename.
    if (std.mem.indexOfScalar(u8, old_path, 0) != null or std.mem.indexOfScalar(u8, new_path, 0) != null) return error.BadPathName;
    const old_z = try std.posix.toPosixPath(old_path);
    const new_z = try std.posix.toPosixPath(new_path);
    while (true) {
        try io.checkCancel();
        const result = std.os.linux.errno(std.os.linux.renameat2(old_dir.handle, &old_z, new_dir.handle, &new_z, .{ .NOREPLACE = true }));
        if (result == .INTR) continue;
        return linuxResult(result);
    }
}

fn linuxResult(result: std.os.linux.E) !void {
    return switch (result) {
        .SUCCESS => {},
        .INVAL, .NOSYS, .OPNOTSUPP => error.OperationUnsupported,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .BUSY => error.FileBusy,
        .DQUOT => error.DiskQuota,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .MLINK => error.LinkQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NOMEM => error.SystemResources,
        .NOSPC => error.NoSpaceLeft,
        .EXIST => error.PathAlreadyExists,
        .NOTEMPTY => error.DirNotEmpty,
        .ROFS => error.ReadOnlyFileSystem,
        .XDEV => error.CrossDevice,
        .ILSEQ => error.BadPathName,
        else => error.Unexpected,
    };
}

test "unsupported non-replacing rename reports failure instead of aborting" {
    const t = std.testing;
    try t.expectError(error.OperationUnsupported, linuxResult(.INVAL));
    try t.expectError(error.OperationUnsupported, linuxResult(.NOSYS));
    try t.expectError(error.PathAlreadyExists, linuxResult(.EXIST));
}
