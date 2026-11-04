## Run wormhook through fleet-actions

`tools/wormhook` wraps the wormhook action at the fleet's pin. If a build job runs
`notambourine/wormhook` after its install step, point it here instead:

```yaml
      - uses: notambourine/fleet-actions/tools/wormhook@<sha> # same tag as your fleet-ci pin
```

The default `mode` is `deep`. Your Dependabot then opens one fleet-actions bump instead of a
separate wormhook bump. Group `notambourine/fleet-actions*` if your config does not already
group all actions, so both references move in one pull request.
