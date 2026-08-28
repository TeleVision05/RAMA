extends SceneTree


func _init() -> void:
	var rows := [
		["head shell L0", MeshKit.head_shell(1.0, 0, 0)],
		["head shell L1", MeshKit.head_shell(1.0, 0, 1)],
		["face cavities", MeshKit.face_cavities(1.0, 0)],
		["eyeball", MeshKit.sphere(MeshKit.EYE_R, 16, 11)],
		["iris cap", MeshKit.spherical_cap(MeshKit.EYE_R * 1.014, 0.50, 12, 3)],
		["eyelid (pair)", MeshKit.eyelid(MeshKit.EYE_R, true, 0)],
		["brows", MeshKit.brows(1.0, 0, 0)],
		["hair jata", MeshKit.hair(1.0, 0, MeshKit.Hair.JATA, 1, 0)],
		["hair loose", MeshKit.hair(1.0, 0, MeshKit.Hair.LOOSE, 1, 0)],
		["hair L1", MeshKit.hair(1.0, 0, MeshKit.Hair.LOOSE, 1, 1)],
		["beard", MeshKit.beard(1.0, 4, 0.9, 0)],
		["hand L0", MeshKit.hand(0.155, 1.0, 2, 1.0, 0)],
		["hand L1 mitten", MeshKit.hand_lod(0.155, 1.0, 2, 1.0)],
		["foot", MeshKit.foot(0.24, 1.0, 1.0, 0)],
		[
			"dhoti",
			MeshKit.skirt(
				0.47, [[0.0, 0.170], [0.15, 0.240], [0.45, 0.228], [0.74, 0.208], [0.92, 0.196], [1.0, 0.176]], 10, 0.080, 0.030, 3, 26
			)
		],
		[
			"uttariya",
			MeshKit.cloth_strip(
				PackedVector3Array(
					[
						Vector3(-0.075, -0.165, 0.112),
						Vector3(-0.02, 0.057, 0.126),
						Vector3(0.07, 0.172, 0.108),
						Vector3(0.14, 0.239, 0.03),
						Vector3(0.132, 0.218, -0.072),
						Vector3(0.08, 0.078, -0.124),
						Vector3(0.01, -0.12, -0.13),
						Vector3(-0.03, -0.285, -0.115)
					]
				),
				0.128,
				0.009,
				0.34,
				3,
				10
			)
		],
		[
			"sword blade",
			MeshKit.blade(
				0.74,
				[
					[0.0, 0.030, 0.0075],
					[0.08, 0.034, 0.008],
					[0.62, 0.032, 0.0068],
					[0.86, 0.027, 0.0052],
					[0.97, 0.014, 0.003],
					[1.0, 0.003, 0.001]
				],
				0.34,
				6
			)
		],
		["arrow fletch", MeshKit.fletch(0.105, 0.019, 0.0016, 0.30)],
		["grip wrap", MeshKit.wrap(0.128, 0.0246, 13.0, 0.0026, 5)],
	]
	for r in rows:
		print("  %-16s %5d tris" % [r[0], (r[1] as ArrayMesh).get_faces().size() / 3])
	quit()
