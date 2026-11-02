shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Rounded props: no flash or dissolve, so no discard and early-z stays effective.
#include "res://shaders/voxel_smooth.gdshaderinc"
