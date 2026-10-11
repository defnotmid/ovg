#!/bin/sh
# Compiles program.slang to the committed SPIR-V and MSL blobs of the
# "program" parity scene. Only needed after editing program.slang.
set -e
cd "$(dirname "$0")"
for unit in vert:vs_main:vertex frag:fs_main:fragment; do
	suffix=${unit%%:*}; rest=${unit#*:}; entry=${rest%%:*}; stage=${rest#*:}
	slangc program.slang -matrix-layout-column-major -O2 -entry "$entry" -stage "$stage" -target spirv -o "program.$suffix.spv"
	spirv-val --target-env vulkan1.2 "program.$suffix.spv"
	slangc program.slang -matrix-layout-column-major -O2 -entry "$entry" -stage "$stage" -target metal -o "program.$suffix.msl"
done
echo "program.slang -> program.{vert,frag}.{spv,msl}"
