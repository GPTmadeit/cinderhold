shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, shadows_disabled;

// Rounded first-person models: they sit inside the player's own shadow-only body.
#define DYNAMIC
#include "res://shaders/voxel_smooth.gdshaderinc"
