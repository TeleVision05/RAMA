class_name CreatureKit
extends RefCounted
## Mesh primitives for things that are not people.
##
## `MeshKit` gives spheres, ovoids, tubes and lofts, and a body built only from those
## reads as a mannequin: every limb is a smooth tapered tube and every horn is a cone.
## What separates a predator from a mannequin at a glance is IRREGULARITY — a horn with
## growth rings that is not the mirror of its partner, a paw with toes in it, a plate of
## armour with a bevelled edge and rivets. Those are the shapes here.
##
## Three rules this file keeps, because breaking either of them costs frames:
##
## 1. **Everything is memoised** on its arguments, like MeshKit, and callers snap their
##    arguments to a coarse grid. A rig build is ~1.3 ms only because the second
##    rakshasa of a given size generates no meshes at all.
## 2. **Detail is baked, not scattered.** A rivet is not a MeshInstance3D. Collect the
##    small parts and hand them to `detail()`, which merges them into ONE instance.
## 3. **Detail carries its own LOD.** `detail()` sets `visibility_range_end`, so ridges,
##    rivets, teeth and claws stop being drawn at `DETAIL_DIST` where they are already
##    sub-pixel. The silhouette-bearing forms go in the base tier and never fade.
##
## The `detail()` instances are also, deliberately, the only member of their material
## group at their joint — see the note on `_tier_mat`.

# ===========================================================================
#  LOD
# ===========================================================================
## Beyond this many metres the fine tier stops drawing. A 1.6 cm rivet on a 2.4 m
## champion is about a third of a pixel at 26 m in a 40-degree lens at 1600 wide, so
## the switch is invisible without needing an alpha fade (which would force every
## detail material to be transparent, and transparency is the expensive kind of cheap).
const DETAIL_DIST := 26.0
## The beast is smaller and closer to the ground; its detail goes sooner.
const BEAST_DETAIL_DIST := 20.0

static var _cache: Dictionary = {}
static var _tier_mats: Dictionary = {}


static func _memo(key: String, gen: Callable) -> ArrayMesh:
	var hit: Variant = _cache.get(key)
	if hit != null:
		return hit
	var m: ArrayMesh = gen.call()
	_cache[key] = m
	return m


static func clear_cache() -> void:
	_cache.clear()
	_tier_mats.clear()


static func cache_size() -> int:
	return _cache.size()


## Bake `parts` (an Array of `{mesh, xform}`) into one MeshInstance3D under `joint`
## that stops drawing past `dist`. Returns null for an empty part list so callers can
## build their list conditionally without guarding every call.
static func detail(joint: Node3D, parts: Array, mat: Material, dist: float = DETAIL_DIST, nm: String = "Detail") -> MeshInstance3D:
	if joint == null or parts.is_empty():
		return null
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = MeshKit.bake_cached(parts)
	mi.material_override = _tier_mat(mat, "detail")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.visibility_range_end = dist
	joint.add_child(mi)
	return mi


## Bake `parts` into one always-drawn MeshInstance3D under `joint`. This is the base
## tier: the silhouette. Use it instead of a dozen loose MeshInstance3Ds, so a horn
## with eleven ridge collars still costs one draw.
static func solid(joint: Node3D, parts: Array, mat: Material, nm: String = "Form") -> MeshInstance3D:
	if joint == null or parts.is_empty():
		return null
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = MeshKit.bake_cached(parts)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	joint.add_child(mi)
	return mi


## A distinct material instance per LOD tier, cached so every rakshasa of a kind
## shares one.
##
## This is not cosmetic. Both mesh mergers in this project — `ProcRig._merge_joint`
## and `RigOptimiser._merge_at` — collapse the meshes that share a joint AND a
## material into one instance, and neither copies `visibility_range_end` onto the
## result. A detail mesh merged into the base mesh next to it would silently lose its
## LOD and be drawn at every distance forever. Giving the tier its own material
## instance leaves it alone in its group, and a group of one is never merged.
static func _tier_mat(mat: Material, tier: String) -> Material:
	if mat == null:
		return null
	var key := "%d|%s" % [mat.get_instance_id(), tier]
	var hit: Variant = _tier_mats.get(key)
	if hit != null:
		return hit
	var dup: Material = mat.duplicate()
	_tier_mats[key] = dup
	return dup


## A part entry for `detail()` / `solid()`.
static func part(mesh: ArrayMesh, pos: Vector3, rot: Vector3 = Vector3.ZERO, scale_v: Vector3 = Vector3.ONE) -> Dictionary:
	var basis := Basis.from_euler(rot).scaled(scale_v)
	return {"mesh": mesh, "xform": Transform3D(basis, pos)}


# ===========================================================================
#  SWEPT GEOMETRY
# ===========================================================================
## Loft a series of rings along an arbitrary curve.
##
## `centres` and `tangents` are per-ring; `radii` are `Vector2(rx, rz)` in the ring's
## own frame; `rolls` twist the cross-section. The frame is parallel-transported so a
## curve that turns through 180 degrees does not pinch or flip.
##
## Winding: `MeshKit.ring` lays a ring out as `X*cos(a) + Z*sin(a)` around an up-axis
## of +Y, and `X x Z = -Y`. The frame here reproduces that relation exactly
## (`e1 = tangent x e2`, so `e1 x e2 = -tangent`), which is why the result is
## front-facing under Godot's CLOCKWISE convention instead of inside out.
static func swept(
	centres: PackedVector3Array,
	tangents: PackedVector3Array,
	radii: PackedVector2Array,
	rolls: PackedFloat32Array,
	segments: int,
	ref_up: Vector3 = Vector3.FORWARD
) -> ArrayMesh:
	var rings: Array = []
	var vs := PackedFloat32Array()
	var e2: Vector3 = ref_up
	var n := centres.size()
	for i in range(n):
		var tg: Vector3 = tangents[i].normalized()
		# Parallel transport: keep as much of the previous reference as is legal.
		e2 = e2 - tg * e2.dot(tg)
		if e2.length_squared() < 1.0e-8:
			e2 = Vector3.RIGHT - tg * Vector3.RIGHT.dot(tg)
			if e2.length_squared() < 1.0e-8:
				e2 = Vector3.FORWARD - tg * Vector3.FORWARD.dot(tg)
		e2 = e2.normalized()
		var e1: Vector3 = tg.cross(e2).normalized()
		var roll: float = rolls[i] if i < rolls.size() else 0.0
		var pts := PackedVector3Array()
		for s in range(segments):
			var a: float = TAU * float(s) / float(segments) + roll
			pts.append(centres[i] + e1 * (cos(a) * radii[i].x) + e2 * (sin(a) * radii[i].y))
		rings.append(pts)
		vs.append(float(i) / float(maxf(1.0, float(n - 1))))
	return MeshKit.loft(rings, vs)


# ===========================================================================
#  HORNS
# ===========================================================================
## A real horn: an arc, not a cone.
##
## `curl` is the total turn in radians about the ring frame's forward axis (positive
## sweeps the tip toward -Z, i.e. forward on a creature whose face is at -Z); `splay`
## turns it outward about the creature's forward axis. `ridges` growth collars are
## raised into the profile, heaviest at the base and dying out toward the tip, which
## is what stops it reading as a smooth cone in a rim light. `chip` shortens and blunts
## the tip, for the horn that has been broken.
##
## Every argument is snapped before it becomes a cache key: two warriors with horns
## that differ by half a millimetre must not each generate their own mesh.
static func horn(
	length: float,
	base_r: float,
	tip_r: float,
	curl: float,
	splay: float,
	twist: float,
	ridges: int,
	ridge_amp: float,
	chip: float = 0.0,
	segments: int = 8,
	steps: int = 26
) -> ArrayMesh:
	var ln: float = snappedf(length, 0.005)
	var br: float = snappedf(base_r, 0.002)
	var tr: float = snappedf(tip_r, 0.001)
	var cu: float = snappedf(curl, 0.02)
	var sp: float = snappedf(splay, 0.02)
	var tw: float = snappedf(twist, 0.02)
	var ra: float = snappedf(ridge_amp, 0.01)
	var ch: float = snappedf(chip, 0.02)
	var key := "horn|%.3f|%.3f|%.3f|%.2f|%.2f|%.2f|%d|%.2f|%.2f|%d|%d" % [ln, br, tr, cu, sp, tw, ridges, ra, ch, segments, steps]
	return _memo(key, func(): return _horn_gen(ln, br, tr, cu, sp, tw, ridges, ra, ch, segments, steps))


static func _horn_gen(
	length: float,
	base_r: float,
	tip_r: float,
	curl: float,
	splay: float,
	twist: float,
	ridges: int,
	ridge_amp: float,
	chip: float,
	segments: int,
	steps: int
) -> ArrayMesh:
	var live: float = 1.0 - clampf(chip, 0.0, 0.6)
	var centres := PackedVector3Array()
	var tangents := PackedVector3Array()
	var radii := PackedVector2Array()
	var rolls := PackedFloat32Array()
	var pos := Vector3.ZERO
	var dir := Vector3.UP
	var ds: float = (length * live) / float(steps)
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		centres.append(pos)
		tangents.append(dir)
		# Taper, then the growth collars on top of it. `pow(1-t, 1.6)` kills the
		# collars near the tip, where a real horn is smooth polished keratin.
		var taper: float = lerpf(base_r, tip_r, pow(t, 0.72))
		# `steps` must comfortably exceed `ridges` or the collars fall between rings and
		# `generate_normals` smooths them out of existence. Measured from
		# build/screenshots/creature_kit.png on 2026-08-28: at 12 steps and 7 ridges the
		# horn rendered as a plain smooth cone with no growth rings at all.
		var collar: float = pow(maxf(0.0, cos(t * float(ridges) * TAU)), 0.55)
		var r: float = taper * (1.0 + ridge_amp * collar * pow(1.0 - t, 1.3))
		if chip > 0.001 and t > 0.90:
			# A snapped horn ends in a blunt stump the width of the shaft, not a point.
			r = lerpf(r, base_r * 0.42, clampf((t - 0.90) / 0.10, 0.0, 1.0))
		# Horns are oval in section, flattened front to back, with a keel on the front.
		radii.append(Vector2(r, r * 0.82))
		rolls.append(twist * t)
		# March the centreline. Rotating the direction by a constant angle per step is
		# a circular arc, which is the shape a horn actually grows in.
		pos += dir * ds
		dir = dir.rotated(Vector3.RIGHT, curl / float(steps)).rotated(Vector3.BACK, splay / float(steps)).normalized()
	return swept(centres, tangents, radii, rolls, segments, Vector3.FORWARD)


# ===========================================================================
#  ARMOUR AND KIT
# ===========================================================================
## A curved plate: one wall of a cylinder, thick enough to have an edge, with the top
## and bottom rims drawn in so it reads as beaten metal rather than a slice of pipe.
## `arc` is how far around it wraps.
static func plate(radius: float, height: float, arc: float, thick: float, segments: int = 10) -> ArrayMesh:
	var rr: float = snappedf(radius, 0.005)
	var hh: float = snappedf(height, 0.005)
	var ar: float = snappedf(arc, 0.05)
	var th: float = snappedf(thick, 0.002)
	return _memo("plate|%.3f|%.3f|%.2f|%.3f|%d" % [rr, hh, ar, th, segments], func(): return _plate_gen(rr, hh, ar, th, segments))


static func _plate_gen(radius: float, height: float, arc: float, thick: float, segments: int) -> ArrayMesh:
	# Built as a closed loop in section: out along the top rim, down the outer face,
	# back along the bottom rim, up the inner face. Lofting that section around `arc`
	# gives a solid shell with real edges.
	var section: Array = [
		Vector2(radius, height * 0.5),
		Vector2(radius + thick, height * 0.42),
		Vector2(radius + thick, -height * 0.42),
		Vector2(radius, -height * 0.5),
	]
	var rings: Array = []
	var vs := PackedFloat32Array()
	for i in range(segments + 1):
		var t: float = float(i) / float(segments)
		var a: float = (t - 0.5) * arc
		# Taper the ends of the wrap so the plate has shoulders instead of square cuts.
		var k: float = 1.0 - pow(absf(t * 2.0 - 1.0), 3.0) * 0.34
		var pts := PackedVector3Array()
		for s in section:
			pts.append(Vector3(sin(a) * s.x, s.y * k, cos(a) * s.x))
		rings.append(pts)
		vs.append(t)
	return MeshKit.loft(rings, vs, true, 1.0)


## A tapered, slightly curved tooth, tusk or claw, built along +Y. POSITIVE `curve`
## bends the tip toward +Z; negative toward -Z. (Measured 2026-08-28 — the docstring
## used to claim the opposite, and the paw was written against the claim, so every
## claw in the project hooked UPWARD off the top of the toe.) Sharper and more
## asymmetric than `MeshKit.tube`, which is what makes a mouthful of them read as
## teeth.
static func fang(length: float, base_r: float, curve: float, segments: int = 6, steps: int = 6) -> ArrayMesh:
	var ln: float = snappedf(length, 0.002)
	var br: float = snappedf(base_r, 0.001)
	var cv: float = snappedf(curve, 0.02)
	return _memo("fang|%.3f|%.3f|%.2f|%d|%d" % [ln, br, cv, segments, steps], func(): return _fang_gen(ln, br, cv, segments, steps))


static func _fang_gen(length: float, base_r: float, curve: float, segments: int, steps: int) -> ArrayMesh:
	var centres := PackedVector3Array()
	var tangents := PackedVector3Array()
	var radii := PackedVector2Array()
	var rolls := PackedFloat32Array()
	var pos := Vector3.ZERO
	var dir := Vector3.UP
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		centres.append(pos)
		tangents.append(dir)
		var r: float = base_r * pow(1.0 - t, 0.62)
		radii.append(Vector2(maxf(r, 0.0006), maxf(r * 0.88, 0.0005)))
		rolls.append(0.0)
		pos += dir * (length / float(steps))
		dir = dir.rotated(Vector3.RIGHT, curve / float(steps)).normalized()
	return swept(centres, tangents, radii, rolls, segments, Vector3.FORWARD)


## A strip of cloth, cord or hide that wraps part-way around a limb, with slack in it.
## `sag` droops the lower edge so it reads as worn rather than painted on.
static func wrap(radius: float, height: float, arc: float, sag: float, segments: int = 12) -> ArrayMesh:
	var rr: float = snappedf(radius, 0.004)
	var hh: float = snappedf(height, 0.004)
	var ar: float = snappedf(arc, 0.05)
	var sg: float = snappedf(sag, 0.004)
	return _memo("wrap|%.3f|%.3f|%.2f|%.3f|%d" % [rr, hh, ar, sg, segments], func(): return _wrap_gen(rr, hh, ar, sg, segments))


static func _wrap_gen(radius: float, height: float, arc: float, sag: float, segments: int) -> ArrayMesh:
	var thick: float = maxf(radius * 0.10, 0.006)
	var rings: Array = []
	var vs := PackedFloat32Array()
	for i in range(segments + 1):
		var t: float = float(i) / float(segments)
		var a: float = (t - 0.5) * arc
		var droop: float = sin(t * PI) * sag
		var top: float = height * 0.5
		var bot: float = -height * 0.5 - droop
		var section: Array = [
			Vector2(radius, top),
			Vector2(radius + thick, top - thick * 0.6),
			Vector2(radius + thick, bot + thick * 0.6),
			Vector2(radius, bot),
		]
		var pts := PackedVector3Array()
		for s in section:
			pts.append(Vector3(sin(a) * s.x, s.y, cos(a) * s.x))
		rings.append(pts)
		vs.append(t)
	return MeshKit.loft(rings, vs, true, 1.0)


## A heavy two-handed cleaver: a thick, notched, top-weighted iron blade on a bound
## haft. The champion's weapon has to read as heavier than the warrior's from across a
## clearing, which is a question of PROFILE — broad and blunt at the far end — rather
## than of length.
static func cleaver(length: float = 1.05) -> Node3D:
	var root := Node3D.new()
	root.name = "Cleaver"
	var m_iron := Mats.flat(Color(0.26, 0.25, 0.26), 0.48, 0.85)
	var m_edge := Mats.flat(Color(0.62, 0.63, 0.66), 0.28, 0.95)
	var m_bind := Mats.flat(Color(0.20, 0.15, 0.12), 0.80)
	var m_bone := Mats.flat(Color(0.80, 0.76, 0.64), 0.42)

	var blade := MeshInstance3D.new()
	blade.mesh = (
		MeshKit
		. profile_loft(
			length * 0.66,
			[
				[0.00, 0.030, 0.016],
				[0.18, 0.058, 0.018],
				[0.46, 0.082, 0.019],
				[0.72, 0.104, 0.018],
				[0.90, 0.098, 0.015],
				[1.00, 0.052, 0.009],
			],
			8
		)
	)
	blade.material_override = m_iron
	blade.position = Vector3(0, length * 0.30, 0)
	root.add_child(blade)

	# The ground edge, offset to one side of the spine so the blade has a bevel.
	var edge := MeshInstance3D.new()
	edge.mesh = (
		MeshKit
		. profile_loft(
			length * 0.60,
			[
				[0.00, 0.022, 0.006],
				[0.50, 0.036, 0.006],
				[1.00, 0.020, 0.004],
			],
			6
		)
	)
	edge.material_override = m_edge
	edge.position = Vector3(0, length * 0.34, 0.013)
	root.add_child(edge)

	# Notches out of the spine: three bites, none of them the same size.
	var notch_r := [0.030, 0.024, 0.034]
	for i in range(3):
		var n := MeshInstance3D.new()
		n.mesh = MeshKit.sphere(notch_r[i], 6, 5)
		n.material_override = m_iron
		n.position = Vector3(0, length * (0.46 + 0.16 * float(i)), -0.070 - 0.012 * float(i % 2))
		root.add_child(n)

	var haft := MeshInstance3D.new()
	haft.mesh = MeshKit.tube(length * 0.42, [[0.0, 0.020], [0.6, 0.023], [1.0, 0.019]], 8)
	haft.material_override = Mats.pbr("wood_beam", 5.0)
	haft.position = Vector3(0, -length * 0.14, 0)
	root.add_child(haft)
	for i in range(3):
		var b := MeshInstance3D.new()
		b.mesh = MeshKit.tube(0.028, [[0.0, 0.026], [1.0, 0.026]], 8)
		b.material_override = m_bind
		b.position = Vector3(0, -length * 0.10 + 0.075 * float(i), 0)
		root.add_child(b)
	var pommel := MeshInstance3D.new()
	pommel.mesh = MeshKit.ovoid(0.030, 0.070, 0.5, 8, 6)
	pommel.material_override = m_bone
	pommel.position = Vector3(0, -length * 0.16, 0)
	root.add_child(pommel)
	return root


# ===========================================================================
#  ANIMAL BODIES
# ===========================================================================
## These are the shared, species-neutral builders. `BeastRig` uses them for the
## vyaghra; `scripts/world/wildlife.gd` owns the chital, the monkeys and the birds and
## is welcome to adopt them — everything here is static, takes only numbers, and
## returns a memoised `ArrayMesh` in a +Y-up, -Z-forward frame.


## A quadruped torso: deep at the chest, pinched at the waist, heavy over the
## haunches. Lofted along +Z (nose end at Z=0), which is the frame every other animal
## part here uses, so no caller has to rotate it a quarter turn and reason about
## whether the winding survived.
##
## `depth` scales the ribcage height, `waist` pinches the loin (0.7 is a cat, 1.0 is a
## barrel), `rump` swells the hindquarters.
static func quadruped_torso(length: float, width: float, depth: float, waist: float, rump: float, segments: int = 14) -> ArrayMesh:
	var ln: float = snappedf(length, 0.01)
	var wd: float = snappedf(width, 0.005)
	var dp: float = snappedf(depth, 0.005)
	var wa: float = snappedf(waist, 0.02)
	var rp: float = snappedf(rump, 0.02)
	return _memo(
		"qtor|%.3f|%.3f|%.3f|%.2f|%.2f|%d" % [ln, wd, dp, wa, rp, segments],
		func(): return _quadruped_torso_gen(ln, wd, dp, wa, rp, segments)
	)


static func _quadruped_torso_gen(length: float, width: float, depth: float, waist: float, rump: float, segments: int) -> ArrayMesh:
	# [t along the body from chest(0) to rump(1), half-width, half-depth, belly drop]
	var prof := [
		[0.00, 0.62, 0.72, 0.10],
		[0.10, 0.86, 0.98, 0.16],
		[0.24, 1.00, 1.08, 0.14],  # behind the shoulder: the deepest point of a cat
		[0.42, 0.88, 0.92, 0.02],
		[0.56, 0.76, 0.76, -0.04],  # the tuck-up: a cat's waist is visibly narrower
		[0.72, 0.92, 0.88, -0.02],
		[0.88, 1.00, 0.94, 0.00],
		[1.00, 0.72, 0.72, 0.02],
	]
	var rings: Array = []
	var vs := PackedFloat32Array()
	for p in prof:
		var t: float = p[0]
		var pinch: float = lerpf(1.0, waist, clampf(1.0 - absf(t - 0.56) / 0.30, 0.0, 1.0))
		var swell: float = lerpf(1.0, rump, clampf((t - 0.60) / 0.34, 0.0, 1.0))
		var rx: float = width * float(p[1]) * pinch * swell
		var rz: float = depth * float(p[2]) * pinch * swell
		# The belly hangs a little below the ring centre; the back does not.
		var drop: float = depth * float(p[3])
		var pts := PackedVector3Array()
		for s in range(segments):
			# The half-turn offset is what puts U = 0.25 on the BELLY. `MeshKit.loft`
			# takes U straight from the ring index, and every other loft in this project
			# is a +Y tube turned a quarter about X, which lands U = 0.25 on the
			# underside. Without the offset this one lands U = 0.25 on the SPINE — so
			# the coat texture painted the tiger's cream belly along its back and its
			# stripes along its stomach (build/screenshots/creature_vyaghra_side.png,
			# 2026-08-28).
			var a: float = TAU * float(s) / float(segments) + PI
			var y: float = sin(a) * rz
			if y < 0.0:
				y -= drop * (-y / maxf(rz, 0.001))
			pts.append(Vector3(cos(a) * rx, y, t * length))
		rings.append(pts)
		vs.append(t)
	# Rings advance along +Z, and the ring frame is (X, Y) with up = +Z; MeshKit.loft
	# wants ring axes (e1, e2) with e1 x e2 = -up, and X x Y = +Z, so the ring order is
	# reversed here to keep the winding front-facing.
	rings.reverse()
	var rv := PackedFloat32Array()
	for i in range(vs.size()):
		rv.append(vs[vs.size() - 1 - i])
	return MeshKit.loft(rings, rv)


## A scapula: the flat blade that rides visibly under a big cat's skin at the withers
## and slides up with every step. A cat with no shoulder blade reads as a table.
static func scapula(length: float, width: float, thick: float) -> ArrayMesh:
	var ln: float = snappedf(length, 0.005)
	var wd: float = snappedf(width, 0.005)
	var th: float = snappedf(thick, 0.004)
	return _memo("scap|%.3f|%.3f|%.3f" % [ln, wd, th], func(): return _scapula_gen(ln, wd, th))


static func _scapula_gen(length: float, width: float, thick: float) -> ArrayMesh:
	var prof := [
		[0.00, 0.30, 0.70],
		[0.22, 0.72, 0.96],
		[0.52, 1.00, 1.00],
		[0.80, 0.86, 0.80],
		[1.00, 0.40, 0.52],
	]
	var rings: Array = []
	var vs := PackedFloat32Array()
	for p in prof:
		var t: float = p[0]
		rings.append(MeshKit.ring(Vector3(0, t * length, 0), width * float(p[1]), 8, (thick / width) / float(p[2])))
		vs.append(t)
	return MeshKit.loft(rings, vs)


## A digitigrade paw: a pad, four toes and their claws, merged into one mesh. Toes are
## what stops a leg ending in a rounded stump. Built pointing along -Z.
static func paw(size: float, claw_len: float, toes: int = 4) -> ArrayMesh:
	var sz: float = snappedf(size, 0.004)
	var cl: float = snappedf(claw_len, 0.003)
	return _memo("paw|%.3f|%.3f|%d" % [sz, cl, toes], func(): return _paw_gen(sz, cl, toes))


## Just the claws of the same paw, in the same places — the fine tier of `paw()`.
## Returning the WHOLE paw again for the detail tier draws a second paw in claw
## material on top of the first one.
static func claws(size: float, claw_len: float, toes: int = 4) -> ArrayMesh:
	var sz: float = snappedf(size, 0.004)
	var cl: float = snappedf(claw_len, 0.003)
	return _memo("claws|%.3f|%.3f|%d" % [sz, cl, toes], func(): return _claws_gen(sz, cl, toes))


static func _claws_gen(size: float, claw_len: float, toes: int) -> ArrayMesh:
	var parts: Array = []
	for i in range(toes):
		var f: float = (float(i) / float(maxf(1.0, float(toes - 1)))) * 2.0 - 1.0
		var tx: float = f * size * 0.62
		var tz: float = -size * 1.02 + absf(f) * size * 0.30
		var tr: float = size * (0.38 - absf(f) * 0.09)
		parts.append(part(fang(claw_len, tr * 0.42, -1.5, 5, 5), Vector3(tx, -size * 0.20, tz - tr * 1.5), Vector3(-PI * 0.52, 0, 0)))
	return MeshKit.bake(parts)


static func _paw_gen(size: float, claw_len: float, toes: int) -> ArrayMesh:
	var parts: Array = []
	# Metacarpal pad: wide, low, and set back under the ankle.
	parts.append(
		part(
			MeshKit.ovoid(size * 1.00, size * 1.30, 0.5, 10, 7),
			Vector3(0, -size * 0.16, -size * 0.10),
			Vector3(PI * 0.5, 0, 0),
			Vector3(1.10, 0.62, 1.0)
		)
	)
	for i in range(toes):
		var f: float = (float(i) / float(maxf(1.0, float(toes - 1)))) * 2.0 - 1.0
		var tx: float = f * size * 0.62
		# The outer toes sit back; the middle two lead. That splay is most of what
		# reads as a paw rather than a mitten.
		var tz: float = -size * 1.02 + absf(f) * size * 0.30
		var tr: float = size * (0.38 - absf(f) * 0.09)
		parts.append(part(MeshKit.ovoid(tr, tr * 2.0, 0.5, 7, 5), Vector3(tx, -size * 0.18, tz), Vector3(PI * 0.5, 0, 0)))
		if claw_len > 0.001:
			parts.append(part(fang(claw_len, tr * 0.42, -1.5, 5, 5), Vector3(tx, -size * 0.20, tz - tr * 1.5), Vector3(-PI * 0.52, 0, 0)))
	return MeshKit.bake(parts)


## A tapering ear with a hollow inner pinna, built along +Y. Cats, deer and monkeys
## all want one; the difference is `pointy` (0 = round like a tiger's, 1 = a spike).
static func ear(height: float, width: float, pointy: float) -> ArrayMesh:
	var hh: float = snappedf(height, 0.004)
	var wd: float = snappedf(width, 0.004)
	var pt: float = snappedf(pointy, 0.05)
	return _memo("ear|%.3f|%.3f|%.2f" % [hh, wd, pt], func(): return _ear_gen(hh, wd, pt))


static func _ear_gen(height: float, width: float, pointy: float) -> ArrayMesh:
	var rings: Array = []
	var vs := PackedFloat32Array()
	var steps := 9
	# `MeshKit.loft` does NOT cap its ends, so a profile that never reaches zero leaves
	# an open tube and the backfaces inside it read as a flat dark card. The first
	# version closed to `sin(PI/4) ^ k`, i.e. 0.82 of full width for a round ear and
	# 0.51 for a pointed one, and photographed as an open-topped bucket on the shelf
	# and as a pair of cardboard flaps on the tiger (build/screenshots/creature_kit.png
	# and creature_vyaghra_head.png, 2026-08-28). `cos` reaches zero at the tip, and the
	# fractional exponent gives it a vertical tangent there, so it closes ROUND rather
	# than as a cone. Measured after the change: max ring radius at t = 1 is 0 m.
	# A collapsed ring at the base closes the other end.
	# Build the cap ring in a LOCAL first: PackedVector3Array is a value type, so
	# `rings.append(PackedVector3Array())` followed by `rings[0].append(...)` mutates a
	# temporary copy and leaves ring 0 empty — which makes `MeshKit.loft` read
	# `n_seg = 0`, emit no triangles, and return a mesh with no surfaces at all.
	var cap := PackedVector3Array()
	for s in range(12):
		var a0: float = TAU * float(s) / 12.0
		cap.append(Vector3(cos(a0) * width * 0.02, 0.0, sin(a0) * width * 0.02))
	rings.append(cap)
	vs.append(0.0)
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		# The rim stays wide most of the way up, then closes: a round ear. `pointy`
		# pulls the closure down toward the base into a triangle.
		var w: float = pow(cos(t * PI * 0.5), lerpf(0.55, 2.2, pointy))
		var rx: float = width * w
		var rz: float = width * w * lerpf(0.42, 0.26, t)
		# Cup it: the front face is pulled back toward the skull.
		var pts := PackedVector3Array()
		var segs := 12
		for s in range(segs):
			var a: float = TAU * float(s) / float(segs)
			var cup: float = -cos(a) * rz * 0.42 * sin(t * PI)
			pts.append(Vector3(cos(a) * rx, t * height, sin(a) * rz + cup))
		rings.append(pts)
		vs.append(t)
	return MeshKit.loft(rings, vs)


## A cloven hoof for the chital deer, built hanging along -Y from the fetlock.
static func hoof(size: float) -> ArrayMesh:
	var sz: float = snappedf(size, 0.003)
	return _memo("hoof|%.3f" % sz, func(): return _hoof_gen(sz))


static func _hoof_gen(size: float) -> ArrayMesh:
	var parts: Array = []
	parts.append(part(MeshKit.ovoid(size * 0.62, size * 1.05, 0.42, 8, 6), Vector3(0, -size * 0.30, 0)))
	for sx in [-1.0, 1.0]:
		parts.append(
			part(
				MeshKit.ovoid(size * 0.40, size * 1.10, 0.30, 7, 5),
				Vector3(sx * size * 0.28, -size * 0.66, -size * 0.06),
				Vector3(0.10, 0, sx * 0.10)
			)
		)
	return MeshKit.bake(parts)


## A branched antler for a chital stag: a beam with two tines, asymmetric by seed.
static func antler(length: float, base_r: float, seed_v: int) -> ArrayMesh:
	var ln: float = snappedf(length, 0.01)
	var br: float = snappedf(base_r, 0.002)
	return _memo("antl|%.3f|%.3f|%d" % [ln, br, seed_v], func(): return _antler_gen(ln, br, seed_v))


static func _antler_gen(length: float, base_r: float, seed_v: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var parts: Array = []
	parts.append(part(horn(length, base_r, base_r * 0.30, 0.75 + rng.randf() * 0.2, 0.55, 0.0, 5, 0.20), Vector3.ZERO))
	# Brow tine, low and forward.
	parts.append(
		part(
			horn(length * 0.36, base_r * 0.62, base_r * 0.16, 0.5, 0.0, 0.0, 3, 0.16),
			Vector3(0, length * 0.16, -base_r * 0.4),
			Vector3(-1.05, 0.25 * rng.randf_range(-1.0, 1.0), 0)
		)
	)
	# Upper fork.
	parts.append(
		part(
			horn(length * 0.50, base_r * 0.58, base_r * 0.12, 0.4, 0.0, 0.0, 3, 0.14),
			Vector3(length * 0.20, length * 0.62, 0),
			Vector3(0.0, 0.0, -0.85 + rng.randf_range(-0.15, 0.15))
		)
	)
	return MeshKit.bake(parts)


## A bird body: a streamlined fuselage with a tail fan, along -Z. Cheap on purpose —
## birds in this world are seen at range and in numbers.
static func bird_body(length: float, girth: float) -> ArrayMesh:
	var ln: float = snappedf(length, 0.005)
	var gr: float = snappedf(girth, 0.003)
	return _memo("bird|%.3f|%.3f" % [ln, gr], func(): return _bird_body_gen(ln, gr))


static func _bird_body_gen(length: float, girth: float) -> ArrayMesh:
	var parts: Array = []
	parts.append(
		part(
			MeshKit.ovoid(girth, length * 0.72, 0.40, 9, 7), Vector3(0, 0, length * 0.06), Vector3(PI * 0.5, 0, 0), Vector3(0.86, 1.0, 1.0)
		)
	)
	parts.append(part(MeshKit.sphere(girth * 0.62, 8, 6), Vector3(0, girth * 0.30, -length * 0.40)))
	parts.append(
		part(
			MeshKit.tube(girth * 0.90, [[0.0, girth * 0.20], [1.0, girth * 0.03]], 5),
			Vector3(0, girth * 0.26, -length * 0.52),
			Vector3(-PI * 0.5, 0, 0)
		)
	)
	# Tail fan.
	for i in range(3):
		var a: float = (float(i) - 1.0) * 0.26
		parts.append(
			part(
				MeshKit.ovoid(girth * 0.24, length * 0.46, 0.5, 5, 4),
				Vector3(sin(a) * girth * 0.5, 0, length * 0.52),
				Vector3(PI * 0.5, a, 0),
				Vector3(1.0, 1.0, 0.22)
			)
		)
	return MeshKit.bake(parts)


## A bird wing as real geometry rather than a card: a tapered, cambered blade that
## still has thickness when seen edge-on.
static func bird_wing(span: float, chord: float) -> ArrayMesh:
	var sp: float = snappedf(span, 0.005)
	var ch: float = snappedf(chord, 0.005)
	return _memo("wing|%.3f|%.3f" % [sp, ch], func(): return _bird_wing_gen(sp, ch))


static func _bird_wing_gen(span: float, chord: float) -> ArrayMesh:
	var rings: Array = []
	var vs := PackedFloat32Array()
	var steps := 6
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var c: float = chord * (1.0 - pow(t, 1.8) * 0.72)
		var thick: float = chord * 0.075 * (1.0 - t * 0.72)
		# Camber: the leading edge lifts as the wing sweeps back.
		var lift: float = sin(t * PI * 0.7) * chord * 0.16
		var pts := PackedVector3Array()
		for s in range(8):
			var a: float = TAU * float(s) / 8.0
			pts.append(Vector3(cos(a) * c * 0.5 + c * 0.10, sin(a) * thick + lift, t * span))
		rings.append(pts)
		vs.append(t)
	rings.reverse()
	var rv := PackedFloat32Array()
	for i in range(vs.size()):
		rv.append(vs[vs.size() - 1 - i])
	return MeshKit.loft(rings, rv)


## A primate hand or foot: a palm and four curled fingers plus a thumb, merged. Monkeys
## are read entirely from their hands and their tail.
static func primate_hand(size: float) -> ArrayMesh:
	var sz: float = snappedf(size, 0.003)
	return _memo("phand|%.3f" % sz, func(): return _primate_hand_gen(sz))


static func _primate_hand_gen(size: float) -> ArrayMesh:
	var parts: Array = []
	parts.append(
		part(MeshKit.ovoid(size * 0.80, size * 1.10, 0.5, 8, 6), Vector3(0, -size * 0.45, 0), Vector3.ZERO, Vector3(1.0, 1.0, 0.52))
	)
	for i in range(4):
		var f: float = (float(i) / 3.0) * 2.0 - 1.0
		parts.append(
			part(
				MeshKit.tube(size * 0.85, [[0.0, size * 0.16], [0.6, size * 0.14], [1.0, size * 0.10]], 5, 1.0, Vector3(0, 0, size * 0.40)),
				Vector3(f * size * 0.52, -size * 0.95, 0),
				Vector3(PI, 0, 0)
			)
		)
	parts.append(
		part(
			MeshKit.tube(size * 0.62, [[0.0, size * 0.18], [1.0, size * 0.11]], 5),
			Vector3(-size * 0.78, -size * 0.70, size * 0.10),
			Vector3(0.4, 0, 2.1)
		)
	)
	return MeshKit.bake(parts)
