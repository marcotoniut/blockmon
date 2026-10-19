# conformance/mutations: does each gate go red when its property goes false?

Each entry breaks one property in the source at HEAD and names the gates that must then fail. A gate that stays green under its mutation cannot fail for that property, whatever its pass count says.

Runs in a detached worktree of HEAD, so the working tree is never touched and uncommitted changes are not tested. Every gate the table names must first pass unmutated, since a gate that is already red catches every mutation. A mutation whose target text no longer occurs exactly once is reported stale, not skipped.

Run from the dev shell with `just mutations`, naming mutation ids to run a subset.

A mutation that fails to compile is reported as unbuilt rather than caught, since a broken build turns every gate red.
