// Battle-channel participant A: one of the two independent processes in the
// Slice B dual-process run. A protocol probe, not a game client.
//
// This program holds A's ephemeral battle secrets and nothing of B's. B is
// reachable only through the anchored public keys in the battle descriptor and
// the frames that arrive on the loopback socket.
//
// The secrets are generated from the system entropy source on first use and
// kept in a file the caller names: no key material is compiled in, so two
// battles never share a key.
package player_a

import ch "../channel"

main :: proc() {
	ch.run(ch.Config{role = .A})
}
