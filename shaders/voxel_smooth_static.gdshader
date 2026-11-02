shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// Rounded props: no flash or dissolve, so no discard and early-z stays effective.
#include "res://shaders/voxel_smooth.gdshaderinc"
