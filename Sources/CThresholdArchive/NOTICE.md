The private headers archive.h and archive_entry.h come from libarchive v3.5.3
(https://github.com/libarchive/libarchive/tree/v3.5.3/libarchive). Their BSD
license notices are retained in the files. No libarchive implementation is
vendored; Threshold XR links macOS's system libarchive. These headers are
private because the macOS SDK ships the library without its C headers.
