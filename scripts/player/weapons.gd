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

	# The grip: a swelled riser with leather WOUND round it. A smooth dowel is a dowel
	# however it is textured, and the hand now closes on this, so the binding is what
	# the fingers sit between.
	var grip := MeshInstance3D.new()
	grip.mesh = MeshKit.tube(0.17, [[0.0, 0.018], [0.14, 0.023], [0.86, 0.023], [1.0, 0.018]], 12, 0.72)
	grip.material_override = Mats.pbr("wood_beam", 4.0)
	grip.position = Vector3(0, -0.085, 0.0)
	root.add_child(grip)
	var bind := MeshInstance3D.new()
	bind.mesh = MeshKit.wrap(0.128, 0.0246, 11.0, 0.0028, 4)
	bind.material_override = Mats.pbr("cloth_indigo", 3.0, "cloth_indigo")
	bind.position = Vector3(0, -0.063, 0.0)
	root.add_child(bind)
	for mirror in [1.0, -1.0]:
		var collar := MeshInstance3D.new()
		collar.mesh = MeshKit.tube(0.055, [[0.0, 0.017], [0.45, 0.022], [1.0, 0.015]], 10)
		collar.material_override = m_brass
		collar.position = Vector3(0, (0.095 if mirror > 0.0 else -0.150), 0.032)
		root.add_child(collar)

		var nock := MeshInstance3D.new()
		nock.mesh = MeshKit.sphere(0.013, 8, 6)
		nock.material_override = m_brass
		nock.position = Vector3(0, pts[n].y * mirror, pts[n].z)
		root.add_child(nock)

		var bell := MeshInstance3D.new()
		bell.mesh = MeshKit.sphere(0.0085, 8, 6)
		bell.material_override = m_brass
		bell.position = Vector3(0, (pts[n].y - 0.022) * mirror, pts[n].z + 0.012)
		root.add_child(bell)

	# Divya Astra manifestation aura on the Kodanda riser.
	var astra_glow := MeshInstance3D.new()
	astra_glow.name = "AstraGlow"
	astra_glow.mesh = MeshKit.sphere(0.042, 12, 8)
	var m_glow := StandardMaterial3D.new()
	m_glow.albedo_color = Color(1.0, 0.72, 0.22, 0.78)
	m_glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m_glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	astra_glow.material_override = m_glow
	astra_glow.position = Vector3(0, 0, -0.05)
	astra_glow.visible = false
	var astra_light := OmniLight3D.new()
	astra_light.name = "Light"
	astra_light.light_color = Color(1.0, 0.72, 0.22)
	astra_light.light_energy = 1.6
	astra_light.omni_range = 3.2
	astra_glow.add_child(astra_light)
	root.add_child(astra_glow)

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
	shaft.rotation = Vector3(-PI * 0.5, 0, 0)
	shaft.position = Vector3(0, 0, 0.30)
	root.add_child(shaft)

	var head := MeshInstance3D.new()
	head.mesh = MeshKit.tube(0.085, [[0.0, 0.0125], [0.35, 0.0105], [1.0, 0.0008]], 6, 0.42)
	head.material_override = Mats.flat(Color(0.42, 0.41, 0.40), 0.34, 0.85)
	head.rotation = Vector3(-PI * 0.5, 0, 0)
	head.position = Vector3(0, 0, -0.42)
	root.add_child(head)

	# Fletching with real geometry: three vanes with a spine, a swept leading edge and
	# a curl, so an arrow in flight still has feathers when it rolls edge-on.
	var m_f := Mats.flat(Color(0.80, 0.36, 0.14), 0.82)
	var vane := MeshKit.fletch(0.105, 0.019, 0.0016, 0.30)
	for i in range(3):
		var f := MeshInstance3D.new()
		f.mesh = vane
		f.material_override = m_f
		f.position = Vector3(0, 0, 0.19)
		f.rotation = Vector3(0, 0, TAU * float(i) / 3.0)
		root.add_child(f)
	# Nock.
	var nk := MeshInstance3D.new()
	nk.mesh = MeshKit.tube(0.020, [[0.0, 0.0055], [0.6, 0.0060], [1.0, 0.0050]], 6)
	nk.material_override = Mats.flat(Color(0.20, 0.16, 0.13), 0.6)
	nk.rotation = Vector3(-PI * 0.5, 0, 0)
	nk.position = Vector3(0, 0, 0.32)
	root.add_child(nk)
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
	var m_f := Mats.flat(Color(0.80, 0.36, 0.14), 0.82)
	for i in range(5):
		var a: float = TAU * float(i) / 5.0
		var s := MeshInstance3D.new()
		s.mesh = MeshKit.tube(0.16, [[0.0, 0.004], [1.0, 0.004]], 5)
		s.material_override = Mats.pbr("wood_beam", 6.0)
		s.position = Vector3(cos(a) * 0.026, 0.40, sin(a) * 0.026)
		s.rotation = Vector3(sin(a) * 0.16, 0, -cos(a) * 0.16)
		root.add_child(s)
		var f := MeshInstance3D.new()
		f.mesh = MeshKit.fletch(0.075, 0.016, 0.0015, 0.30)
		f.material_override = m_f
		f.position = Vector3(cos(a) * 0.026, 0.47, sin(a) * 0.026)
		f.rotation = Vector3(-PI * 0.5, a, 0)
		root.add_child(f)
	return root


## Khanda-inspired straight sword: broad blade, reinforced spine, disc pommel.
static func sword() -> Node3D:
	var root := Node3D.new()
	root.name = "Sword"
	var m_steel := Mats.flat(Color(0.72, 0.74, 0.78), 0.18, 0.95)
	var m_brass := Mats.brass()

	# A khanda blade: a fuller down each face and a bevel that runs out to an edge.
	# Lofted as an ellipse this was a rounded bar and read as blunt from every angle.
	var blade := MeshInstance3D.new()
	blade.mesh = (
		MeshKit
		. blade(
			0.74,
			[
				[0.00, 0.030, 0.0075],
				[0.08, 0.034, 0.0080],
				[0.62, 0.032, 0.0068],
				[0.86, 0.027, 0.0052],
				[0.97, 0.014, 0.0030],
				[1.00, 0.003, 0.0010],
			],
			0.34,
			6
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

	# Lotus-shaped golden crossguard bolster (Padma-mukha bolster).
	var bolster := MeshInstance3D.new()
	bolster.mesh = MeshKit.profile_loft(
		0.058,
		[
			[0.0, 0.024, 0.015],
			[0.35, 0.038, 0.018],
			[0.75, 0.032, 0.012],
			[1.0, 0.018, 0.008],
		],
		12
	)
	bolster.material_override = m_brass
	bolster.position = Vector3(0, 0.098, 0)
	root.add_child(bolster)

	var grip := MeshInstance3D.new()
	grip.mesh = MeshKit.tube(0.14, [[0.0, 0.016], [0.5, 0.0145], [1.0, 0.016]], 10, 0.72)
	grip.material_override = Mats.pbr("wood_beam", 5.0)
	grip.position = Vector3(0, -0.055, 0)
	root.add_child(grip)
	var wind := MeshInstance3D.new()
	wind.mesh = MeshKit.wrap(0.118, 0.0172, 9.0, 0.0023, 4)
	wind.material_override = Mats.pbr("cloth_indigo", 3.0, "cloth_indigo")
	wind.position = Vector3(0, -0.045, 0)
	root.add_child(wind)

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
		. blade(
			0.62,
			[
				[0.0, 0.028, 0.011],
				[0.30, 0.052, 0.013],
				[0.70, 0.046, 0.011],
				[0.92, 0.030, 0.008],
				[1.0, 0.006, 0.003],
			],
			0.16,
			5
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
	s.mesh = MeshKit.tube(1.62, [[0.0, 0.019], [0.4, 0.016], [0.8, 0.015], [1.0, 0.021]], 8, 1.0, Vector3(0.02, 0, 0.01))
	s.material_override = Mats.pbr("wood_beam", 4.0)
	s.position = Vector3(0, -0.8, 0)
	root.add_child(s)
	return root


## Hanuman's iconic golden fluted bulbous mace (Kaumodaki / Gada).
static func gada() -> Node3D:
	var root := Node3D.new()
	root.name = "Gada"
	var m_brass := Mats.brass()
	var m_wood := Mats.pbr("wood_beam", 4.0)

	# Ringed shaft with pommel bulb.
	var shaft := MeshInstance3D.new()
	shaft.mesh = MeshKit.tube(
		0.72,
		[
			[0.0, 0.026],
			[0.08, 0.018],
			[0.55, 0.021],
			[0.85, 0.028],
			[1.0, 0.042],
		],
		12
	)
	shaft.material_override = m_wood
	shaft.position = Vector3(0, -0.18, 0)
	root.add_child(shaft)

	for ry in [-0.14, 0.16, 0.38]:
		var ring_mi := MeshInstance3D.new()
		ring_mi.mesh = MeshKit.tube(0.024, [[0.0, 0.028], [0.5, 0.033], [1.0, 0.028]], 12)
		ring_mi.material_override = m_brass
		ring_mi.position = Vector3(0, ry, 0)
		root.add_child(ring_mi)

	# Lotus neck and heavy golden spherical/fluted mace head with finial spire.
	var head := MeshInstance3D.new()
	head.mesh = MeshKit.tube(
		0.36,
		[
			[0.00, 0.044],
			[0.18, 0.105],
			[0.45, 0.138],
			[0.68, 0.118],
			[0.84, 0.052],
			[0.95, 0.022],
			[1.00, 0.004],
		],
		16
	)
	head.material_override = m_brass
	head.position = Vector3(0, 0.52, 0)
	root.add_child(head)

	var flange := MeshInstance3D.new()
	flange.mesh = MeshKit.tube(0.032, [[0.0, 0.142], [0.5, 0.156], [1.0, 0.142]], 16)
	flange.material_override = m_brass
	flange.position = Vector3(0, 0.66, 0)
	root.add_child(flange)
	return root


## Ravana's curved golden-hilted crescent war-blade (Chandrahasa).
static func chandrahasa() -> Node3D:
	var root := Node3D.new()
	root.name = "Chandrahasa"
	var m_steel := Mats.flat(Color(0.76, 0.80, 0.88), 0.16, 0.96)
	var m_brass := Mats.brass()

	var blade := MeshInstance3D.new()
	blade.mesh = MeshKit.blade(
		0.86,
		[
			[0.00, 0.034, 0.008],
			[0.25, 0.042, 0.009],
			[0.58, 0.056, 0.008],
			[0.82, 0.048, 0.006],
			[0.95, 0.024, 0.004],
			[1.00, 0.004, 0.001],
		],
		0.28,
		7
	)
	blade.material_override = m_steel
	blade.position = Vector3(0, 0.11, 0)
	blade.rotation = Vector3(0.08, 0, 0)
	root.add_child(blade)

	var guard := MeshInstance3D.new()
	guard.mesh = MeshKit.tube(0.036, [[0.0, 0.052], [0.5, 0.068], [1.0, 0.038]], 12, 0.45)
	guard.material_override = m_brass
	guard.position = Vector3(0, 0.085, 0)
	root.add_child(guard)

	var grip := MeshInstance3D.new()
	grip.mesh = MeshKit.tube(0.16, [[0.0, 0.020], [0.5, 0.017], [1.0, 0.021]], 10)
	grip.material_override = m_brass
	grip.position = Vector3(0, -0.065, 0)
	root.add_child(grip)
	return root
