const std = @import("std");
const windows = std.os.windows;
const WORD = windows.WORD;
const BOOL = windows.BOOL;
const unexpectedError = windows.unexpectedError;
const GetLastError = windows.kernel32.GetLastError;
pub const HANDLE = windows.HANDLE;
pub const FILETIME = windows.FILETIME;

pub const SYSTEMTIME = extern struct {
    wYear: WORD,
    wMonth: WORD,
    wDayOfWeek: WORD,
    wDay: WORD,
    wHour: WORD,
    wMinute: WORD,
    wSecond: WORD,
    wMilliseconds: WORD,
};
const Inner = struct {
    pub extern "kernel32" fn GetFileTime(
        hFile: HANDLE,
        lpCreationTime: ?*FILETIME,
        lpLastAccessTime: ?*FILETIME,
        lpLastWriteTime: ?*FILETIME,
    ) callconv(.winapi) BOOL;
    pub extern "kernel32" fn FileTimeToLocalFileTime(
        lpFileTime: ?*const FILETIME,
        lpLocalFileTime: ?*FILETIME,
    ) callconv(.winapi) BOOL;
    pub extern "kernel32" fn FileTimeToSystemTime(
        lpFileTime: ?*const FILETIME,
        lpSystemTime: ?*SYSTEMTIME,
    ) callconv(.winapi) BOOL;
};
pub inline fn GetFileTime(
    hFile: HANDLE,
    lpCreationTime: ?*FILETIME,
    lpLastAccessTime: ?*FILETIME,
    lpLastWriteTime: ?*FILETIME,
) !void {
    if (Inner.GetFileTime(
        hFile,
        lpCreationTime,
        lpLastAccessTime,
        lpLastWriteTime,
    ) == 0)
        return unexpectedError(GetLastError());
}
pub inline fn FileTimeToLocalFileTime(
    lpFileTime: ?*const FILETIME,
    lpLocalFileTime: ?*FILETIME,
) !void {
    if (Inner.FileTimeToLocalFileTime(
        lpFileTime,
        lpLocalFileTime,
    ) == 0)
        return unexpectedError(GetLastError());
}
pub inline fn FileTimeToSystemTime(
    lpFileTime: ?*const FILETIME,
    lpSystemTime: ?*SYSTEMTIME,
) !void {
    if (Inner.FileTimeToSystemTime(
        lpFileTime,
        lpSystemTime,
    ) == 0)
        return unexpectedError(GetLastError());
}
