# Third-Party Notices

This repository is a fork of NVIDIA Omniverse PhysX. It carries the
upstream third-party components unchanged, so their notices and license
files are kept in place and registered here.

## NVIDIA Omniverse PhysX

| Field | Value |
|-------|-------|
| Repository | `https://github.com/NVIDIA-Omniverse/PhysX.git` |
| Branch | `main` |
| Tag | `ovphysx-0.4.9` |
| Commit | `34ce3ed80821f91c88fe02ace9c454280983b50a` |
| License | `BSD-3-Clause` |
| Local path | repository root |

The NVIDIA sources keep their original copyright and license notices. The
Hygon HCU/HIP changes are described in `NOTICE`; unchanged upstream files
receive no additional file header.

## Vulkan-Headers

| Field | Value |
|-------|-------|
| Local path | `flow/external/vulkan` |
| License | `Apache-2.0 OR MIT` |
| License file | `flow/external/vulkan/LICENSE.md` |
| Origin | carried unchanged from the upstream commit above |

Used as-is; no Hygon modification.

## GLFW

| Field | Value |
|-------|-------|
| Local path | `flow/external/glfw` |
| License | GLFW zlib/libpng license |
| License file | `flow/external/glfw/COPYING.txt` |
| Origin | carried unchanged from the upstream commit above |

The bundled `COPYING.txt` is the GLFW zlib/libpng license. The compliance
scanner does not map it to one of the auto-approved SPDX identifiers, so the
component is registered here and needs legal confirmation before release.
Used as-is; no Hygon modification.

## ovphysx binary distribution

| Field | Value |
|-------|-------|
| Local path | `ovphysx/licenses/LICENSE-binary.txt` |
| License | NVIDIA Enterprise Software license terms (proprietary) |
| Origin | carried unchanged from the upstream commit above |

`ovphysx` binaries ship under NVIDIA enterprise terms rather than an
open-source license, so redistribution needs legal confirmation before
release.

## Pending legal review

The two items below could not be auto-classified by the compliance scanner
and must be confirmed and approved by legal/compliance before this
repository is published. Until that sign-off is recorded they remain
release blockers:

- `flow/external/glfw/COPYING.txt` - confirm the GLFW zlib/libpng license.
- `ovphysx/licenses/LICENSE-binary.txt` - confirm the NVIDIA binary license
  terms and the permitted distribution scope.
