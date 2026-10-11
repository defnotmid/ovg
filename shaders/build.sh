#!/usr/bin/env bash
# Compiles ovg.slang to the SPIR-V (Vulkan) and MSL (Metal) blobs the
# SDL_GPU backend #loads. Only needed after editing the shader; the outputs
# are committed. DXIL (D3D12) is produced when slangc's dxc works; Windows
# otherwise runs on Vulkan.
set -euo pipefail
cd "$(dirname "$0")"

FLAGS=(-matrix-layout-column-major -O2)
for unit in vert:vs_main frag:fs_main; do
	IFS=: read -r suffix entry <<<"$unit"
	slangc ovg.slang "${FLAGS[@]}" -entry "$entry" -target spirv -o "ovg.$suffix.spv"
	slangc ovg.slang "${FLAGS[@]}" -entry "$entry" -target metal -o "ovg.$suffix.msl"
	if ! slangc ovg.slang "${FLAGS[@]}" -entry "$entry" -target dxil -o "ovg.$suffix.dxil" 2>/dev/null; then
		rm -f "ovg.$suffix.dxil"
		echo "  note: no DXIL for $suffix (slangc's dxc failed)" >&2
	fi
	echo "  ovg.slang:$entry -> ovg.$suffix.{spv,msl}"
done
spirv-val --target-env vulkan1.2 ovg.vert.spv
spirv-val --target-env vulkan1.2 ovg.frag.spv
