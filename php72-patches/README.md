# php7.2 patches

Each `*.patch` file here is added to Ubuntu's php7.2 quilt series in name
order, so prefix them with a number (`0001-...`). Patches must apply to the
`php7.2-7.2.24` source tree with `-p1`; the build fails if one does not.

Bump `PHP72_LOCAL_SUFFIX` in the Dockerfile (`+cylo1`, `+cylo2`, ...) whenever
the set of patches changes, and add a regression check under
`release/regression/` for the issue each patch fixes.
