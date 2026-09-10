# Dependabot's docker ecosystem rewrites this line, tag and digest together. The upstream
# release assets are not a pin any updater rewrites, so the image is what Dependabot can
# hold; the digest replaces the cosign and sha256 checks the release download needed.
FROM ghcr.io/betterleaks/betterleaks:v1.8.1@sha256:8b9d12db5e11ca798029da44923503de5d8cfff6992cffaaa6722fbeb9fc7797

COPY scripts/run-betterleaks.sh /run-betterleaks.sh

# The upstream entrypoint is `betterleaks` itself; the wrapper assembles the scan.
ENTRYPOINT ["/run-betterleaks.sh"]
