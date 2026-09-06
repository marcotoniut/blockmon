// Instrumentation, not protocol: the observable form of the cost axis
// canonical-encoding.md §7 states normatively ("one leaf hash and 256 node
// hashes, independent of domain size"). Without it that clause can only be
// restated, never measured, which is what conformance/bounded-access does.
//
// Thread-local, so the test runner's parallel threads each count their own
// work and nothing synchronises on the hot path.
package canonical

@(thread_local)
hash_calls: u64

hash_calls_reset :: proc() {
	hash_calls = 0
}
