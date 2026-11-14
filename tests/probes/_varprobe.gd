extends SceneTree


func _init() -> void:
	for i in range(10):
		var r := ProcRig.new()
		r.configure({"seed": 40 + i * 13, "skin": "skin_warm", "cloth": "cloth_saffron", "cloth2": "cloth_white", "topknot": false})
		r._quantise()
		r._derive_variety()
		print(
			(
				"seed %4d -> face %d hair %d beard %.2f belly %.2f sh %.2f garment %s"
				% [40 + i * 13, r.cfg.face, r.cfg.hair_style, r.cfg.beard_len, r.cfg.belly, r.cfg.shoulders, r.cfg.garment]
			)
		)
	quit()
