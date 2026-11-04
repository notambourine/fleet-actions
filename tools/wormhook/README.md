# wormhook

Run [wormhook](https://github.com/notambourine/wormhook) after a repository's own install step.
`fleet-ci` uses the same action, so the fleet pin is the only wormhook pin a caller tracks.

## Tests

`test/ACTION-LEVEL` lists the covering self-test jobs. A planted positive would put a live IOC in
the tree, so the wormhook repository's own suite covers detection.
