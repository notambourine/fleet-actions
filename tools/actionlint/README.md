# actionlint

Check workflows with [kjanat/actionlint](https://github.com/kjanat/actionlint). Its image includes
ShellCheck and pyflakes.

## Dependency pin

Release tags reference a mutable container tag. The immutable digest lands later on the floating
`v1.N` tag.

`Dockerfile` pins the image by tag and digest so Dependabot can update both. `action.yml` mirrors
the upstream inputs and positional arguments.

## Tests

`test/ACTION-LEVEL` lists the covering self-test jobs.
