shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// Rounded characters: hit flash and death dissolve.
#define DYNAMIC
#include "res://shaders/voxel_smooth.gdshaderinc"
