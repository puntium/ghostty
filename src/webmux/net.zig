//! webmux client networking: everything the native client says to a
//! webmux host, over the host's HTTP unix socket (directly, or through the
//! ssh tunnel's local socket). Pure Zig, Linux, no GTK, no Ghostty imports.
//!
//!   Conn       unix stream socket: deadlines, buffered reads, interrupt()
//!   http       HTTP/1.1 client: buffered fetch, streamed download into a
//!              writer, incremental body Stream, streamed request bodies
//!   websocket  RFC 6455 client: blocking reader, thread-safe sends,
//!              interrupt() for prompt shutdown
//!   sse        server-sent events reader (GET /api/fs/watch)
//!   protocol   session WebSocket frames, JSON both directions
//!   api        typed session API: health, list, create, delete
//!
//! Standard library use: std.Io.Mutex (send serialization, interrupt vs
//! close), std.Io.random (WebSocket keys and masks), std.json, std.base64,
//! std.crypto.hash.Sha1, std.Io.Writer/Reader as the body sink/source.
//! std.http.Client is not used: its unix-socket support is a thin TCP-pool
//! shim without per-request deadlines or a way to interrupt a blocked read,
//! and std has no WebSocket client (only std.http.Server's server side) and
//! no SSE support.
pub const Conn = @import("net/Conn.zig");
pub const http = @import("net/http.zig");
pub const websocket = @import("net/websocket.zig");
pub const WebSocket = websocket.WebSocket;
pub const sse = @import("net/sse.zig");
pub const protocol = @import("net/protocol.zig");
pub const api = @import("net/api.zig");
pub const TestHost = @import("net/testhost.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("net/test_live.zig");
}
