shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Rounded characters: hit flash and death dissolve.
#define DYNAMIC
#include "res://shaders/voxel_smooth.gdshaderinc"
