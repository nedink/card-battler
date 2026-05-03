shader_type canvas_item;

// Fakes a lit 3D sphere on a square quad. The quad's UVs are interpreted as
// a unit disc; pixels outside the disc are discarded so corners don't show.
// The base color is set per-instance from card.gd based on the
// planet's type (or the average of its types when more than one applies).

uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform vec3 light_dir = vec3(-0.45, -0.55, 0.7);
uniform float ambient : hint_range(0.0, 1.0) = 0.18;
uniform float rim_strength : hint_range(0.0, 1.0) = 0.55;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.45;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r2 = dot(p, p);
	if (r2 > 1.0) {
		discard;
	}
	float z = sqrt(1.0 - r2);
	vec3 normal = vec3(p.x, p.y, z);
	vec3 ld = normalize(light_dir);
	float diff = max(dot(normal, ld), 0.0);
	float spec = pow(diff, 24.0) * specular_strength;
	float rim = pow(1.0 - z, 3.0) * rim_strength;
	vec3 col = base_color.rgb * (ambient + diff) + base_color.rgb * rim + vec3(spec);
	// Soft anti-aliased disc edge.
	float edge = smoothstep(1.0, 0.985, r2);
	COLOR = vec4(col, edge);
}
