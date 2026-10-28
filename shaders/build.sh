#!/usr/bin/env bash
# Compiles ovg.slang to the SPIR-V (Vulkan) and MSL (Metal) blobs the
# SDL_GPU backend #loads. Only needed after editing the shader; the outputs
# are committed. DXIL (D3D12) is produced when slangc's dxc works; Windows
# otherwise runs on Vulkan.
set -euo pipefail
cd "$(dirname "$0")"

# ocurves' curves.slang (exact shapes' coverage) from its checkout beside ovg.
FLAGS=(-matrix-layout-column-major -O2 -I ../../ocurves)
# The layout of the curves words that curves.slang reads (ocurves'
# curves.FORMAT), from the same checkout: ovg_sdlgpu refuses to build
# against an ocurves with another.
FORMAT=$(sed -n 's/^FORMAT :: \([0-9][0-9]*\).*/\1/p' ../../ocurves/curves.odin)
if [ -z "$FORMAT" ]; then
	echo "no FORMAT in ../../ocurves/curves.odin" >&2
	exit 1
fi
for unit in vert:vs_main frag:fs_main shape_vert:vs_shape shape_frag:fs_shape shape_box_frag:fs_shape_box shape_group_frag:fs_shape_group shape_hairline_frag:fs_shape_hairline marker_group_frag:fs_marker_group; do
	IFS=: read -r suffix entry <<<"$unit"
	slangc ovg.slang "${FLAGS[@]}" -entry "$entry" -target spirv -o "ovg.$suffix.spv"
	slangc ovg.slang "${FLAGS[@]}" -entry "$entry" -target metal -o "ovg.$suffix.msl"
	if ! slangc ovg.slang "${FLAGS[@]}" -entry "$entry" -target dxil -o "ovg.$suffix.dxil" 2>/dev/null; then
		rm -f "ovg.$suffix.dxil"
		echo "  note: no DXIL for $suffix (slangc's dxc failed)" >&2
	fi
	echo "  ovg.slang:$entry -> ovg.$suffix.{spv,msl}"
done
for blob in vert frag shape_vert shape_frag shape_box_frag shape_group_frag shape_hairline_frag marker_group_frag; do
	spirv-val --target-env vulkan1.2 "ovg.$blob.spv"
done
cat >../sdlgpu/curves_format.odin <<EOF
package ovg_sdlgpu

// Written by shaders/build.sh: the ocurves format (curves.FORMAT) the
// committed shape shaders read.
SHADERS_CURVES_FORMAT :: $FORMAT
EOF
echo "  curves format $FORMAT -> sdlgpu/curves_format.odin"
