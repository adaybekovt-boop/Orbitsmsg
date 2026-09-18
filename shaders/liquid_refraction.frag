#include <flutter/runtime_effect.glsl>

// Impeller ImageFilter.shader contract:
//   • first uniform (vec2) is overwritten with the bound backdrop size
//   • first sampler2D is the live backdrop behind the glass
// Displacement is sampled from a second texture (liquid-disp-map.webp).
uniform vec2 u_size;
uniform float u_strength;
uniform sampler2D u_texture_input;
uniform sampler2D u_disp;

out vec4 frag_color;

void main() {
  vec2 uv = FlutterFragCoord().xy / max(u_size, vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec2 map_uv = clamp(uv, 0.0, 1.0);
  vec4 map = texture(u_disp, map_uv);
  vec2 offset = (map.rg - vec2(0.5)) * u_strength;
  vec2 sample_uv = clamp(uv + offset, 0.0, 1.0);
  frag_color = texture(u_texture_input, sample_uv);
}
