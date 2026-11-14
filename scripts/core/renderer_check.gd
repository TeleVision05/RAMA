class_name RendererCheck
extends RefCounted
## What the graphics card can run, and what to tell the player when it cannot do it all.
##
## RAMA is built for the Forward+ renderer. Godot quietly falls back to a weaker one when
## the card or driver cannot offer it; the game then has no volumetric fog, no ambient
## occlusion and no GPU particles worth the name. Rather than render something broken, the
## game drops to its Low tier (which turns those effects off) and says so in plain words.

const MSG_FALLBACK := (
	"Your graphics card can't run RAMA's full visuals, so it is using the simplest settings. "
	+ "It will look plainer but play the same. A newer graphics driver may help."
)
const MSG_UNKNOWN := (
	"RAMA couldn't tell what your graphics card supports, so it is using the simplest settings. "
	+ "If the picture looks wrong, update your graphics driver."
)


## For a rendering-method name (RenderingServer.get_current_rendering_method()), returns
## {"supported": bool, "max_tier": int (Quality.Tier), "message": String ("" if fine)}.
static func assess(method: String) -> Dictionary:
	match method:
		"forward_plus", "mobile":
			return {"supported": true, "max_tier": Quality.Tier.ULTRA, "message": ""}
		"dummy":
			# A headless run (tests, servers). There is no card to apologise for.
			return {"supported": true, "max_tier": Quality.Tier.ULTRA, "message": ""}
		"gl_compatibility":
			return {"supported": false, "max_tier": Quality.Tier.LOW, "message": MSG_FALLBACK}
		_:
			push_warning("[renderer] unrecognised rendering method '%s'" % method)
			return {"supported": false, "max_tier": Quality.Tier.LOW, "message": MSG_UNKNOWN}
