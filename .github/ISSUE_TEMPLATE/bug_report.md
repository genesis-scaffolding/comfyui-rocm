---
name: Bug report
about: Something is broken with a built image or the build process
title: ""
labels: ["bug"]
assignees: []
---

## What happened

<!-- A clear, short description of the bug. -->

## Image tag

<!-- Which image tag were you running? e.g. v0.34.0-cuda-13.0-amd64 -->

```

```

## Host environment

```bash
uname -a
nvidia-smi
docker info | grep -iE 'runtime|nvidia'
```

## How to reproduce

```bash
# Commands you ran, in order
```

## Expected behaviour

<!-- What you expected to happen. -->

## Actual behaviour

<!-- What actually happened. Paste logs if available. -->

## Checks

- [ ] I checked the [Releases page](../../releases) and confirmed the image tag I'm using was published successfully.
- [ ] I searched [existing issues](../../issues) for this problem.
- [ ] My NVIDIA driver is newer than the minimum listed for my CUDA version (see [GPU-COMPATIBILITY](../../blob/main/docs/GPU-COMPATIBILITY.md)).
