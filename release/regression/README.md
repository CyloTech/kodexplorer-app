# Regression checks

Each `*.sh` file here is mounted read-only into the image at
`/release/regression/` and run with `sh`. It must exit 0 only when the issue
it covers is fixed. Add one for the 21 October 2026 multipart/form-data
issue once a safe reproducer is available.
