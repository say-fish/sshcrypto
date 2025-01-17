const std = @import("std");

const zssh = @import("zssh");

const Ed25519 = zssh.cert.Ed25519;
const Pem = zssh.cert.Pem;
const PublicKey = std.crypto.sign.Ed25519.PublicKey;
const Signature = std.crypto.sign.Ed25519.Signature;

const MAX_RUNS: usize = 0x01 << 16;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator = gpa.allocator();

    defer if (gpa.deinit() == .leak) @panic("LEAK");

    const pem = try Pem.parse(@embedFile("ed25519-cert.pub"));
    var der = try pem.decode(allocator);
    defer der.deinit();

    var timer = try std.time.Timer.start();

    for (0..MAX_RUNS) |_| {
        const cert = try Ed25519.from_bytes(der.data);

        const signature = Signature.fromBytes(
            cert.signature.ed25519.sm[0..64].*,
        );
        const pk = try PublicKey.fromBytes(
            cert.signature_key.ed25519.pk[0..32].*,
        );

        std.mem.doNotOptimizeAway(
            try signature.verify(der.data[0..cert.enconded_sig_size()], pk),
        );
    }

    const elapsed = timer.read();

    std.debug.print("Parsed and verified Ed25519 SSH cert, {} times\n", .{MAX_RUNS});
    std.debug.print(
        "Verify took ~= {}ns ({} verifications/s)\n",
        .{ elapsed / MAX_RUNS, 1000000000 / (@as(f64, @floatFromInt(elapsed)) / MAX_RUNS) },
    );
}
