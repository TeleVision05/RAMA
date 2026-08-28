class_name Weapons
extends RefCounted
## Rama's arms, built as geometry. The Kodanda longbow, arrows, a khanda sword and a
## quiver. All procedurally generated so they match the rest of the world's look.


static func bow(scale_f: float = 1.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Bow"
	var m_wood := Mats.pbr("wood_beam", 3.0)
	var m_brass := Mats.brass()
	var m_string := Mats.flat(Color(0.86, 0.82, 0.70), 0.75)

	# A recurve limb profile: the stave curves away from the archer, then the tips
	# curve back. Built as one lofted stave mirrored top and bottom.
	var pts: Array[Vector3] = []
	var radii: Array[float] = []
	var n := 16
	for i in range(n + 1):
		var t: float = float(i) / float(n)
		var y: float = t * 0.78
		# Belly curve plus a recurve flick at the tip.
		var z: float = sin(t * PI * 0.86) * 0.14 - pow(t, 4.0) * 0.20
		pts.append(Vector3(0, y, z))
		radii.append(lerpf(0.016, 0.006, pow(t, 0.8)))

	for mirror in [1.0, -1.0]:
		var rings: Array = []
		var vs := PackedFloat32Array()
		for i in range(pts.size()):
			var c := pts[i]
			c.y *= mirror
			var r := MeshKit.ring(c, radii[i], 8, 0.62)
			rings.append(r)
			vs.append(float(i) / float(pts.size() - 1))
		var mi := MeshInstance3D.new()
		mi.mesh = MeshKit.loft(rings, vs)
		mi.material_override = m_wood
		root.add_child(mi)

	# Grip wrap and brass nocks.
	var grip := MeshInstance3D.new()
	grip.mesh = MeshKit.tube(0.16, [[0.0, 0.019], [0.15, 0.023], [0.85, 0.023], [1.0, 0.019]], 10, 0.7)
	grip.material_override = Mats.pbr("cloth_indigo", 4.0, "cloth_indigo")
	grip.position = Vector3(0, -0.08, 0.0)
	root.add_child(grip)
	for mirror in [1.0, -1.0]:
		var nock := MeshInstance3D.new()
		nock.mesh = MeshKit.sphere(0.013, 8, 6)
		nock.material_override = m_brass
		nock.position = Vector3(0, pts[n].y * mirror, pts[n].z)
		root.add_child(nock)

	# The string, which the animation pulls back.
	var st := MeshInstance3D.new()
	st.name = "String"
	st.mesh = MeshKit.tube(pts[n].y * 2.0, [[0.0, 0.0022], [1.0, 0.0022]], 5)
	st.material_override = m_string
	st.position = Vector3(0, -pts[n].y, pts[n].z)
	root.add_child(st)

	root.scale = Vector3.ONE * scale_f
	return root


static func arrow() -> Node3D:
	var root := Node3D.new()
	root.name = "Arrow"
	var shaft := MeshInstance3D.new()
	# Points along -Z, which is Godot's forward, so the projectile flies where it looks.
	shaft.mesh = MeshKit.tube(0.72, [[0.0, 0.0042], [1.0, 0.0038]], 6)
	shaft.material_override = Mats.pbr("wood_beam", 6.0)
	shaft.rotation = Vector3(PI * 0.5, 0, 0)
	shaft.position = Vector3(0, 0, 0.30)
	root.add_child(shaft)

	var head := MeshInstance3D.new()
	head.mesh = MeshKit.tube(0.085, [[0.0, 0.0125], [0.35, 0.0105], [1.0, 0.0008]], 6, 0.42)
	head.material_override = Mats.flat(Color(0.42, 0.41, 0.40), 0.34, 0.85)
	head.rotation = Vector3(PI * 0.5, 0, 0)
	head.position = Vector3(0, 0, -0.42)
	root.add_child(head)

	var m_f := Mats.flat(Color(0.80, 0.36, 0.14), 0.85)
	m_f.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in range(3):
		var f := MeshInstance3D.new()
		f.mesh = MeshKit.quad(0.055, 0.10)
		f.material_override = m_f
		f.position = Vector3(0, 0, 0.30)
		f.rotation = Vector3(0, 0, TAU * float(i) / 3.0)
		f.rotate_object_local(Vector3.UP, PI * 0.5)
		root.add_child(f)
	return root


static func quiver() -> Node3D:
	var root := Node3D.new()
	root.name = "Quiver"
	var body := MeshInstance3D.new()
	body.mesh = (
		MeshKit
		. profile_loft(
			0.42,
			[
				[0.0, 0.052, 0.052],
				[0.15, 0.058, 0.058],
				[0.9, 0.062, 0.062],
				[1.0, 0.060, 0.060],
			],
			12
		)
	)
	body.material_override = Mats.pbr("wood_beam", 2.0)
	root.add_child(body)
	var band := MeshInstance3D.new()
	band.mesh = MeshKit.tube(0.03, [[0.0, 0.064], [1.0, 0.064]], 12)
	band.material_override = Mats.brass()
	band.position = Vector3(0, 0.34, 0)
	root.add_child(band)
	# Fletchings poking out of the top.
	var m_f := Mats.flat(Color(0.80, 0.36, 0.14), 0.85)
	m_f.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in range(5):
		var a: float = TAU * float(i) / 5.0
		var s := MeshInstance3D.new()
		s.mesh = MeshKit.tube(0.16, [[0.0, 0.004], [1.0, 0.004]], 5)
		s.material_override = Mats.pbr("wood_beam", 6.0)
		s.position = Vector3(cos(a) * 0.026, 0.40, sin(a) * 0.026)
		s.rotation = Vector3(sin(a) * 0.16, 0, -cos(a) * 0.16)
		root.add_child(s)
		var f := MeshInstance3D.new()
		f.mesh = MeshKit.quad(0.04, 0.075)
		f.material_override = m_f
		f.position = Vector3(cos(a) * 0.026, 0.52, sin(a) * 0.026)
		f.rotation = Vector3(0, a, 0)
		root.add_child(f)
	return root


## Khanda-inspired straight sword: broad blade, reinforced spine, disc pommel.
static func sword() -> Node3D:
	var root := Node3D.new()
	root.name = "Sword"
	var m_steel := Mats.flat(Color(0.72, 0.74, 0.78), 0.18, 0.95)
	var m_brass := Mats.brass()

	var blade := MeshInstance3D.new()
	blade.mesh = (
		MeshKit
		. profile_loft(
			0.74,
			[
				[0.00, 0.030, 0.0085],
				[0.10, 0.033, 0.0090],
				[0.62, 0.031, 0.0075],
				[0.86, 0.026, 0.0058],
				[1.00, 0.004, 0.0018],
			],
			10
		)
	)
	blade.material_override = m_steel
	blade.position = Vector3(0, 0.10, 0)
	root.add_child(blade)

	var guard := MeshInstance3D.new()
	guard.mesh = MeshKit.box(Vector3(0.16, 0.022, 0.030))
	guard.material_override = m_brass
	guard.position = Vector3(0, 0.09, 0)
	root.add_child(guard)

	var grip := MeshInstance3D.new()
	grip.mesh = MeshKit.tube(0.14, [[0.0, 0.017], [0.5, 0.015], [1.0, 0.017]], 10, 0.72)
	grip.material_override = Mats.pbr("cloth_indigo", 5.0, "cloth_indigo")
	grip.position = Vector3(0, -0.055, 0)
	root.add_child(grip)

	var pommel := MeshInstance3D.new()
	pommel.mesh = MeshKit.tube(0.020, [[0.0, 0.020], [0.5, 0.034], [1.0, 0.018]], 12, 1.0)
	pommel.material_override = m_brass
	pommel.position = Vector3(0, -0.072, 0)
	root.add_child(pommel)
	return root


## Crude rakshasa weapon: a heavy notched cleaver.
static func crude_blade() -> Node3D:
	var root := Node3D.new()
	var m := Mats.flat(Color(0.34, 0.32, 0.30), 0.55, 0.7)
	var blade := MeshInstance3D.new()
	blade.mesh = (
		MeshKit
		. profile_loft(
			0.62,
			[
				[0.0, 0.028, 0.012],
				[0.30, 0.052, 0.014],
				[0.70, 0.046, 0.012],
				[0.92, 0.030, 0.009],
				[1.0, 0.006, 0.004],
			],
			8
		)
	)
	blade.material_override = m
	blade.position = Vector3(0, 0.12, 0)
	root.add_child(blade)
	var grip := MeshInstance3D.new()
	grip.mesh = MeshKit.tube(0.17, [[0.0, 0.019], [1.0, 0.021]], 8)
	grip.material_override = Mats.pbr("wood_beam", 5.0)
	grip.position = Vector3(0, -0.06, 0)
	root.add_child(grip)
	return root


## A wooden staff for elders and travellers.
static func staff() -> Node3D:
	var root := Node3D.new()
	var s := MeshInstance3D.new()
	s.mesh = MeshKit.tube(
		1.62, [[0.0, 0.019], [0.4, 0.016], [0.8, 0.015], [1.0, 0.021]], 8, 1.0, Vector3(0.02, 0, 0.01)
	)
	s.material_override = Mats.pbr("wood_beam", 4.0)
	s.position = Vector3(0, -0.8, 0)
	root.add_child(s)
	return root
