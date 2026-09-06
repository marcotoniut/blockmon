// Battle-channel participant B: one of the two independent processes in the
// Slice B dual-process run. A protocol probe, not a game client.
//
// This program holds B's ephemeral battle secrets and nothing of A's. A is
// reachable only through the anchored public keys in the battle descriptor and
// the frames that arrive on the loopback socket.
//
// The secrets are generated from the system entropy source on first use and
// kept in a file the caller names: no key material is compiled in, so two
// battles never share a key.
package player_b

import ch "../channel"

main :: proc() {
	ch.run(ch.Config{role = .B})
}
