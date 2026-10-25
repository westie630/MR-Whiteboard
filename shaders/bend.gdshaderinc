// The curved desk (DeskBend): a flat canvas is bent into a surface that lies on the desk, curves up through a quarter circle at a set
// distance and then climbs the wall. The surface is a cylinder, so lengths along it are kept: the canvas is not stretched. The mesh must
// have been cut into short strips (DeskBend.slice) for a vertex shader to bend a long triangle without cutting the corner.
// Must agree with DeskBend.surface_to_node().
uniform vec4 bend_a = vec4(0.0);                         // x: 1 when bent, y: where the flat part ends (surface distance), z: the radius
uniform vec2 bend_pan = vec2(0.0);                       // canvas -> surface offset: the contents slide along the surface by this
uniform vec4 bend_win = vec4(-1e6, -1e6, 1e6, 1e6);      // the shown part of the surface (u0, s0, u1, s1): what slides out is hidden

// c: a canvas position (x, y); the position on the surface (u, s), for desk_clipped().
vec2 desk_surf(vec3 c) {
	return bend_a.x < 0.5 ? c.xy : c.xy + bend_pan;
}

// c: a canvas position (x, y, height). Returns the position in the frame's space.
vec3 desk_bend(vec3 c) {
	if (bend_a.x < 0.5) {
		return c;
	}
	float at = bend_a.y;
	float r = max(bend_a.z, 0.001);
	float u = c.x + bend_pan.x;
	float s = c.y + bend_pan.y;
	float h = c.z;
	float arc = 1.5707963 * r;
	if (s <= at) {
		return vec3(u, s, h);
	}
	if (s <= at + arc) {
		float p = (s - at) / r;
		return vec3(u, at + (r - h) * sin(p), r - (r - h) * cos(p));
	}
	return vec3(u, at + r - h, r + (s - at - arc));
}

bool desk_clipped(vec2 surf) {
	return bend_a.x > 0.5 && (surf.x < bend_win.x || surf.y < bend_win.y || surf.x > bend_win.z || surf.y > bend_win.w);
}
