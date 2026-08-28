class_name DialogueData
extends RefCounted
## Every conversation in Panchavati, as data.
##
## A TREE is `{speaker, entries, nodes}`.
##   entries  ordered list of `{node, condition}` — the first whose condition passes is
##            where the conversation starts. This is how an NPC stops introducing
##            themselves once you have met them.
##   nodes    id -> `{speaker, text, choices, next, action}`
##            `text` may be a String or an Array of Strings (one is picked at random,
##            which is what makes idle small talk bearable on the fourth visit).
##            `choices` entries are `{text, next, condition, action}` — a choice whose
##            condition fails is not shown at all.
##
## Condition and action grammar is documented in DialogueSystem.
##
## House style for the writing: two or three short sentences, never more. No modern
## idiom. The villagers talk about the things in front of them — clay, rain, goats,
## the river, the dark under the trees — and the elder and the traveller are allowed
## to be characters rather than signposts.

static var _trees: Dictionary = {}


static func all() -> Dictionary:
	if _trees.is_empty():
		_build()
	return _trees


static func tree(id: String) -> Dictionary:
	return all().get(id, {})


static func has(id: String) -> bool:
	return all().has(id)


static func ids() -> Array:
	return all().keys()


static func _build() -> void:
	_trees = {
		"elder": _elder(),
		"potter": _potter(),
		"weaver": _weaver(),
		"farmer": _farmer(),
		"herder": _herder(),
		"fisherman": _fisherman(),
		"mother": _mother(),
		"child_ila": _ila(),
		"child_puru": _puru(),
		"guard": _guard(),
		"traveller": _traveller(),
		"hermit": _hermit(),
	}


# ===========================================================================
#  Suryadatta — the elder. Dry, unhurried, speaks in small verdicts.
# ===========================================================================
static func _elder() -> Dictionary:
	var hub: Array = [
		{"text": "Tell me of the shrine on the east knoll.", "next": "e_shrine"},
		{"text": "What of the traveller on the road?", "condition": "flag:met_bhadra", "next": "e_bhadra"},
		{"text": "How goes the harvest?", "next": "e_harvest"},
		{"text": "Nothing more. Rest well, grandfather.", "next": ""},
	]
	return {
		"speaker": "Suryadatta",
		"entries":
		[
			{"node": "e_intro", "condition": "!seen:e_intro"},
			{"node": "e_idle"},
		],
		"nodes":
		{
			"e_intro":
			{
				"text":
				"So. The stranger with the tall bow. Panchavati sees few travellers and fewer archers — stand in the shade, it costs nothing.",
				"choices":
				[
					{"text": "Who speaks for this village?", "next": "e_who"},
					{"text": "Is all well here?", "next": "e_trouble"},
					{"text": "I came only for water.", "next": "e_water"},
				],
			},
			"e_who":
			{
				"text":
				"I do, as my father did. Eleven households, forty-one souls, and one well that argues with all of us.",
				"next": "e_hub",
			},
			"e_trouble":
			{
				"text":
				"The forest has grown loud after dark. Not tiger. Not wolf. Something that laughs and then stops laughing.",
				"choices":
				[
					{"text": "Has anyone been hurt?", "next": "e_hurt"},
					{"text": "I will walk out and look.", "next": "e_look"},
				],
			},
			"e_hurt":
			{
				"text": "Not yet. Gopa has lost two goats, and Gopa does not lose goats.",
				"next": "e_hub",
			},
			"e_look":
			{
				"action": "flag:elder_asked_help=true",
				"text":
				"Then go carefully, and come back to tell an old man he worried over nothing. I would enjoy being wrong.",
				"next": "e_hub",
			},
			"e_water":
			{
				"text":
				"Then drink deep. The Godavari has never once refused anybody, which is more than I can say for this village.",
				"next": "e_hub",
			},
			"e_hub":
			{
				"text":
				[
					"Was there anything else?",
					"Ask, then. My afternoon is not busy.",
					"Speak up. My ears are older than my opinions.",
				],
				"choices": hub.duplicate(true),
			},
			"e_shrine":
			{
				"action": "flag:heard_of_shrine=true",
				"text":
				"My mother swept its steps at every dawn of her life. Now the lamp is dark and the moss "
						+ "has the stairway. Stone remembers longer than we do.",
				"next": "e_hub",
			},
			"e_bhadra":
			{
				"text": "Bhadra? He arrives with news and leaves with our rice. Both are fair trade, most years.",
				"next": "e_hub",
			},
			"e_harvest":
			{
				"text": "The rain came early, then thought better of it. We will eat. We will not boast.",
				"next": "e_hub",
			},
			"e_idle":
			{
				"text":
				[
					"Sit if your legs are tired. Standing is for young men and herons.",
					"My knees tell the weather better than any almanac.",
					"You walk quietly for a man carrying that much wood and string.",
				],
				"choices": hub.duplicate(true),
			},
		},
	}


# ===========================================================================
#  Ghatikara — the potter.
# ===========================================================================
static func _potter() -> Dictionary:
	var hub: Array = [
		{"text": "Where do you dig your clay?", "next": "k_clay"},
		{"text": "Could you spare a pot?", "condition": "!flag:potter_gift", "next": "k_gift"},
		{"text": "I will leave you to the wheel.", "next": ""},
	]
	return {
		"speaker": "Ghatikara",
		"entries":
		[
			{"node": "k_intro", "condition": "!seen:k_intro"},
			{"node": "k_idle"},
		],
		"nodes":
		{
			"k_intro":
			{
				"text": "Mind the drying line behind you. One careless elbow and I lose a morning.",
				"choices":
				[
					{"text": "My apologies. Is the clay good here?", "next": "k_clay"},
					{"text": "How many do you make in a day?", "next": "k_count"},
				],
			},
			"k_clay":
			{
				"text":
				"The best lies at the river bend below the fields. Grey, sweet, no grit in it. I would not trade that bank for silver.",
				"next": "k_hub",
			},
			"k_count":
			{
				"text": "Nine water pots before the sun turns. Twelve, if nobody talks to me.",
				"next": "k_hub",
			},
			"k_gift":
			{
				"action": ["give:clay_pot:1", "flag:potter_gift=true"],
				"text":
				"Take the small one. The rim is a little proud, so it is mine and not a customer's. Carry water in it and think well of me.",
				"next": "k_hub",
			},
			"k_hub":
			{
				"text": ["Anything else?", "Speak while my hands are busy."],
				"choices": hub.duplicate(true),
			},
			"k_idle":
			{
				"text":
				[
					"A pot is only earth that agreed to hold something.",
					"Do not buy from the man at the ford. His rims weep.",
					"Wet clay forgives everything. Fired clay forgives nothing.",
				],
				"choices": hub.duplicate(true),
			},
		},
	}


# ===========================================================================
#  Ratnavali — the weaver.
# ===========================================================================
static func _weaver() -> Dictionary:
	var hub: Array = [
		{"text": "How is the indigo made?", "next": "w_indigo"},
		{"text": "Do the caravans still come?", "next": "w_sell"},
		{"text": "I will let you work.", "next": ""},
	]
	return {
		"speaker": "Ratnavali",
		"entries":
		[
			{"node": "w_intro", "condition": "!seen:w_intro"},
			{"node": "w_idle"},
		],
		"nodes":
		{
			"w_intro":
			{
				"text": "Careful of the loom-string. It has taken three of my fingernails and it is still hungry.",
				"choices":
				[
					{"text": "That indigo is beautiful.", "next": "w_indigo"},
					{"text": "Who buys your cloth?", "next": "w_sell"},
				],
			},
			"w_indigo":
			{
				"text":
				"Six dips and a day in the sun for each. The colour is not in the cloth — it is in the waiting.",
				"next": "w_hub",
			},
			"w_sell":
			{
				"text": "The caravan men, when they come. They come less each year, and pay less each time they come.",
				"next": "w_hub",
			},
			"w_hub":
			{
				"text": ["Yes?", "Was there more?"],
				"choices": hub.duplicate(true),
			},
			"w_idle":
			{
				"text":
				[
					"Saffron for festivals, white for grief, indigo for every ordinary day.",
					"My grandmother wove the cloth the shrine lamp stands on. It is still up there, I expect.",
					"Feel it. Four days of my life, and it will outlast me.",
				],
				"choices": hub.duplicate(true),
			},
		},
	}


# ===========================================================================
#  Halin — the farmer.
# ===========================================================================
static func _farmer() -> Dictionary:
	var hub: Array = [
		{"text": "Tell me about the boar.", "next": "f_boar"},
		{"text": "How stands the crop?", "next": "f_crop"},
		{"text": "Good harvest to you.", "next": ""},
	]
	return {
		"speaker": "Halin",
		"entries":
		[
			{"node": "f_intro", "condition": "!seen:f_intro"},
			{"node": "f_idle"},
		],
		"nodes":
		{
			"f_intro":
			{
				"text": "If you have come about the boar, I have said everything I intend to say about the boar.",
				"choices":
				[
					{"text": "What boar?", "next": "f_boar"},
					{"text": "I came about nothing. How stands the crop?", "next": "f_crop"},
				],
			},
			"f_boar":
			{
				"text": "A big one, out of the west forest. It walked through my bund as if the rice were owed to it.",
				"next": "f_hub",
			},
			"f_crop":
			{
				"text": "Thin. The rain came early and left early, like a guest with somewhere better to be.",
				"next": "f_hub",
			},
			"f_hub":
			{
				"text": ["Well?", "Say it quickly, the light is going."],
				"choices": hub.duplicate(true),
			},
			"f_idle":
			{
				"text":
				[
					"Straight rows are a lie you tell the field. It plants itself crooked anyway.",
					"Three more days of this and I can flood the low plot.",
					"You stand on the bund, not in it. Thank you.",
				],
				"choices": hub.duplicate(true),
			},
		},
	}


# ===========================================================================
#  Gopa — the herder. Carries the small quest: Bindu's bell.
# ===========================================================================
static func _herder() -> Dictionary:
	return {
		"speaker": "Gopa",
		"entries":
		[
			{"node": "gp_done", "condition": "quest:q_lost_goat:complete"},
			{"node": "gp_active", "condition": "quest:q_lost_goat:active"},
			{"node": "gp_intro", "condition": "!seen:gp_intro"},
			{"node": "gp_idle"},
		],
		"nodes":
		{
			"gp_intro":
			{
				"text": "Do not stand behind the brown one. She kicks, and she has excellent aim.",
				"choices":
				[
					{"text": "You keep a fine herd.", "next": "gp_herd"},
					{"text": "Something is troubling you.", "next": "gp_lost"},
				],
			},
			"gp_herd":
			{
				"text": "Nineteen. It was twenty-one at the last moon.",
				"next": "gp_lost",
			},
			"gp_lost":
			{
				"text": "Two gone in eight days. Not wolf-work — wolves leave a mess, and these left nothing at all.",
				"choices":
				[
					{"text": "Where did you lose them?", "next": "gp_where"},
					{"text": "I will look for them.", "next": "gp_accept"},
				],
			},
			"gp_where":
			{
				"text":
				"Up the west track, where the trees close over the road. Bindu wore a brass bell — you would hear her long before you saw her.",
				"next": "gp_ask",
			},
			"gp_ask":
			{
				"text":
				"If you are walking that way, and you have the look of a man who does, bring me the bell at least.",
				"choices":
				[
					{"text": "I will find it.", "next": "gp_accept"},
					{"text": "Not today. I am sorry.", "next": ""},
				],
			},
			"gp_accept":
			{
				"action": ["quest_start:q_lost_goat", "flag:gopa_asked=true"],
				"text": "Brass, with a split lip. Bring it and I will not ask what else you found up there.",
				"next": "",
			},
			"gp_active":
			{
				"text":
				[
					"Any sign? The west track, past where the light turns green.",
					"Still nineteen. I count them twice a day now, like a miser.",
				],
				"choices":
				[
					{
						"text": "I found Bindu's bell.",
						"condition": "item:goat_bell",
						"action": ["take:goat_bell:1", "quest_complete:q_lost_goat", "give:healing_salve:2"],
						"next": "gp_give"
					},
					{"text": "Not yet. I will keep looking.", "next": ""},
				],
			},
			"gp_give":
			{
				"text":
				"...Thank you. Take this — turmeric and neem, and it is the best thing I own. Do not go up there after dark, whatever you are.",
				"next": "",
			},
			"gp_done":
			{
				"text":
				[
					"Nineteen, and nineteen is what I will have at the next moon. I have decided.",
					"I hung the bell on the gatepost. It rings when the wind comes off the forest, and I like knowing.",
				],
				"choices": [{"text": "Peace to your herd.", "next": ""}],
			},
			"gp_idle":
			{
				"text":
				[
					"Goats are cleverer than rice and less grateful than dogs.",
					"They will not go west now. They know something I am still arguing about.",
				],
				"choices":
				[
					{"text": "Have you lost any more?", "condition": "flag:gopa_asked", "next": "gp_lost"},
					{"text": "Good day to you.", "next": ""},
				],
			},
		},
	}


# ===========================================================================
#  Kevat — the fisherman at the bank.
# ===========================================================================
static func _fisherman() -> Dictionary:
	var hub: Array = [
		{"text": "Have you seen anything strange on the water?", "next": "kv_strange"},
		{"text": "Could you spare a fish?", "condition": "!flag:kevat_gift", "next": "kv_fish"},
		{"text": "Good fishing to you.", "next": ""},
	]
	return {
		"speaker": "Kevat",
		"entries":
		[
			{"node": "kv_intro", "condition": "!seen:kv_intro"},
			{"node": "kv_idle"},
		],
		"nodes":
		{
			"kv_intro":
			{
				"text": "Softly — they can hear your shadow. ...There. Gone. That was my breakfast, walking away.",
				"choices":
				[
					{"text": "My apologies. I will tread lighter.", "next": "kv_ok"},
					{"text": "Is the river falling?", "next": "kv_river"},
				],
			},
			"kv_ok":
			{
				"text": "Sit anyway. A man who apologises to a fisherman is a rare thing, and worth a morning.",
				"next": "kv_hub",
			},
			"kv_river":
			{
				"text": "Falling. By the hot months you will cross at the ford and wet nothing above the ankle.",
				"next": "kv_hub",
			},
			"kv_strange":
			{
				"text": "Lights on the far bank, two nights back, moving south. No boat carries a light that colour.",
				"action": "flag:heard_river_lights=true",
				"next": "kv_hub",
			},
			"kv_fish":
			{
				"action": ["give:river_fish:1", "flag:kevat_gift=true"],
				"text": "Take it. Salt and fire, nothing else, whatever they tell you in the cities.",
				"next": "kv_hub",
			},
			"kv_hub":
			{
				"text": ["Anything else, while the water is quiet?", "Yes?"],
				"choices": hub.duplicate(true),
			},
			"kv_idle":
			{
				"text":
				[
					"The river gives on its own schedule. Arguing costs you the morning.",
					"My father drowned in this water and I still call it kind. Explain that to a city man.",
					"Herons upstream. That means the shallows have moved again.",
				],
				"choices": hub.duplicate(true),
			},
		},
	}


# ===========================================================================
#  Sulochana — mother of Ila and Puru.
# ===========================================================================
static func _mother() -> Dictionary:
	var hub: Array = [
		{"text": "Your children are well?", "next": "m_kids"},
		{"text": "Can I help with anything?", "condition": "!flag:watch_children", "next": "m_help"},
		{"text": "I will not keep you.", "next": ""},
	]
	return {
		"speaker": "Sulochana",
		"entries":
		[
			{"node": "m_intro", "condition": "!seen:m_intro"},
			{"node": "m_idle"},
		],
		"nodes":
		{
			"m_intro":
			{
				"text": "Ila! Puru! — forgive me. Two children and one pot of water, and only the pot behaves.",
				"choices":
				[
					{"text": "They seem fine children.", "next": "m_kids"},
					{"text": "Can I help?", "next": "m_help"},
				],
			},
			"m_kids":
			{
				"text": "They are loud children. Fine is what I hope for by evening.",
				"next": "m_hub",
			},
			"m_help":
			{
				"action": ["flag:watch_children=true", "event:watch_children"],
				"text":
				"Keep half an eye on them at the square, if you are going that way. They have started walking to the treeline on a dare.",
				"next": "m_hub",
			},
			"m_hub":
			{
				"text": ["Was there something else?", "Yes, friend?"],
				"choices": hub.duplicate(true),
			},
			"m_idle":
			{
				"text":
				[
					"There is rice if you are hungry. Do not argue, there is always rice.",
					"Puru did not sleep. He says the wind stopped to listen to him.",
					"Water, meal, water, meal. The days are round here.",
				],
				"choices": hub.duplicate(true),
			},
		},
	}


# ===========================================================================
#  Ila — the bold one.
# ===========================================================================
static func _ila() -> Dictionary:
	return {
		"speaker": "Ila",
		"entries":
		[
			{"node": "i_intro", "condition": "!seen:i_intro"},
			{"node": "i_idle"},
		],
		"nodes":
		{
			"i_intro":
			{
				"text": "Are you a soldier? Puru says you are a soldier. I said you are too quiet for one.",
				"choices":
				[
					{"text": "I am only a traveller.", "next": "i_trav"},
					{"text": "What are you playing?", "next": "i_play"},
				],
			},
			"i_trav":
			{
				"text": "Travellers have dust on them. You have dust on you. Very well — you are a traveller.",
				"next": "",
			},
			"i_play":
			{
				"text": "Counting herons. Puru cheats. He counts the same one twice and then looks pleased.",
				"next": "",
			},
			"i_idle":
			{
				"text":
				[
					"I can run to the big stone and back before Amma finishes a sentence.",
					"Do not tell Puru, but I went as far as the second tree yesterday.",
					"Shoot something! ...Not a bird. Not a bird!",
				],
				"choices": [{"text": "Another time. Stay near the square.", "next": ""}],
			},
		},
	}


# ===========================================================================
#  Puru — the careful one.
# ===========================================================================
static func _puru() -> Dictionary:
	return {
		"speaker": "Puru",
		"entries":
		[
			{"node": "p_intro", "condition": "!seen:p_intro"},
			{"node": "p_idle"},
		],
		"nodes":
		{
			"p_intro":
			{
				"text": "...You are very tall.",
				"choices":
				[
					{"text": "What is your name?", "next": "p_name"},
					{"text": "Are you well, little one?", "next": "p_well"},
				],
			},
			"p_name":
			{
				"text": "Puru. Ila is my sister. She is not afraid of anything, so I have to be afraid for both of us.",
				"next": "",
			},
			"p_well":
			{
				"text":
				"There was a noise last night. Amma said it was the wind. The wind does not stop when you listen to it.",
				"action": "flag:puru_heard_noise=true",
				"next": "",
			},
			"p_idle":
			{
				"text":
				[
					"I am not going past the second tree. Ila can go alone.",
					"Do you sleep outside? Where do you put your back?",
					"That bow is taller than me.",
				],
				"choices": [{"text": "Stay near your mother.", "next": ""}],
			},
		},
	}


# ===========================================================================
#  Vikrama — the gate guard.
# ===========================================================================
static func _guard() -> Dictionary:
	var hub: Array = [
		{"text": "Do you get much trouble here?", "next": "g_trouble"},
		{"text": "Who set you at this gate?", "next": "g_who"},
		{"text": "Keep a good watch.", "next": ""},
	]
	return {
		"speaker": "Vikrama",
		"entries":
		[
			{"node": "g_intro", "condition": "!seen:g_intro"},
			{"node": "g_idle"},
		],
		"nodes":
		{
			"g_intro":
			{
				"text":
				"Hold. ...No, walk on. You carry that bow like a man who has used it, and that is not yet a crime.",
				"choices":
				[
					{"text": "Do you get much trouble here?", "next": "g_trouble"},
					{"text": "Who set you at this gate?", "next": "g_who"},
				],
			},
			"g_trouble":
			{
				"text":
				"Not at this gate. West, where the road goes under the trees — we stopped walking that after dark, and nobody had to say why.",
				"next": "g_hub",
			},
			"g_who":
			{
				"text": "Suryadatta. I asked him for the post. Somebody should stand where the road comes in.",
				"next": "g_hub",
			},
			"g_hub":
			{
				"text": ["Something else?", "Speak, I am not going anywhere."],
				"choices": hub.duplicate(true),
			},
			"g_idle":
			{
				"text":
				[
					"Quiet road today. I have counted four goats and a heron.",
					"If you go west, go before the light does.",
					"There is water in the jar by the post. Take some, it is for everyone.",
				],
				"choices": hub.duplicate(true),
			},
		},
	}


# ===========================================================================
#  Bhadra — the traveller on the road. The hook for the first errand.
# ===========================================================================
static func _traveller() -> Dictionary:
	return {
		"speaker": "Bhadra",
		"entries":
		[
			{"node": "b_thanks", "condition": ["quest:q_shrine:complete", "!flag:bhadra_thanked"]},
			{"node": "b_done", "condition": "quest:q_shrine:complete"},
			{"node": "b_waiting", "condition": "quest:q_shrine:active"},
			{"node": "b_intro", "condition": "!seen:b_intro"},
			{"node": "b_idle"},
		],
		"nodes":
		{
			"b_intro":
			{
				"action": "flag:met_bhadra=true",
				"text":
				"Sit! No — you sit. I have been sitting since Kishkindha and my feet have opinions. Bhadra, trader in small things.",
				"choices":
				[
					{"text": "Where have you come from?", "next": "b_where"},
					{"text": "You look shaken.", "next": "b_shaken"},
				],
			},
			"b_where":
			{
				"text":
				"East. Past the shrine knoll. I have slept beside that shrine on eight years of journeys — this time I did not.",
				"next": "b_why",
			},
			"b_shaken":
			{
				"text": "I am a merchant, so I am always shaken, and it is always about money. Not tonight, though.",
				"next": "b_why",
			},
			"b_why":
			{
				"text":
				"The lamp at the shrine was dead, and the dark up there had a shape to it. I walked all night rather than lie down.",
				"choices":
				[
					{"text": "What lamp?", "next": "b_lamp"},
					{"text": "You are safe here.", "next": "b_safe"},
				],
			},
			"b_safe":
			{
				"text":
				"Safe and useless, which is the usual condition of a traveller. Let me be useful for one moment.",
				"next": "b_lamp",
			},
			"b_lamp":
			{
				"action": "flag:heard_of_shrine=true",
				"text":
				"A stone lamp on the shrine's threshold. Oil, wick, flame. The east road has been lit by it since before my father walked it.",
				"choices":
				[
					{"text": "I will climb up and light it.", "next": "b_accept"},
					{"text": "Someone from the village should go.", "next": "b_villagers"},
				],
			},
			"b_villagers":
			{
				"text": "They will not. The woman who used to is dead, and the young ones have fields and reasons.",
				"next": "b_flatter",
			},
			"b_flatter":
			{
				"text":
				"But you carry a bow, and you have the face of a man who finishes what he starts. Forgive me — "
						+ "I trade in small things, and I read people for a living.",
				"choices":
				[
					{"text": "Then I will light it.", "next": "b_accept"},
					{"text": "Perhaps tomorrow.", "next": "b_later"},
				],
			},
			"b_later":
			{
				"text": "Tomorrow is a fine day. It has never once arrived empty-handed. I will be here.",
				"next": "",
			},
			"b_accept":
			{
				"action":
				["quest_start:q_shrine", "give:lamp_oil:1", "flag:heard_of_shrine=true", "event:shrine_errand_taken"],
				"text":
				"Then take my oil. Good til oil, and I have no more use for a dark road. Rishi Vamadeva keeps "
						+ "the knoll — tell him Bhadra still owes him a bowl of rice.",
				"next": "b_accept_2",
			},
			"b_accept_2":
			{
				"speaker": "Rama",
				"text": "I will tell him. Rest here, and eat. The village is kind.",
				"next": "",
			},
			"b_waiting":
			{
				"text":
				[
					"East, and up. You cannot miss the steps — they are the only straight thing on that hill.",
					"Still here? The lamp will not light itself, and I have made that joke twice today.",
				],
				"choices":
				[
					{"text": "Which way, again?", "next": "b_dir"},
					{"text": "I am going now.", "next": ""},
				],
			},
			"b_dir":
			{
				"text":
				"East across the ford, then the knoll with the crooked palm on it. Climb until the wind changes.",
				"next": "",
			},
			"b_thanks":
			{
				"action": ["flag:bhadra_thanked=true", "give:healing_salve:1", "event:bhadra_gift"],
				"text":
				"I saw the light from the road last night. Small, and orange, and eight years old to me. Take this salve — I will not hear otherwise.",
				"next": "",
			},
			"b_done":
			{
				"text":
				[
					"I will sleep at the shrine again on the way back. That is worth more than the cloth in my pack.",
					"They will see that lamp from the ford tonight, and not one of them will know who lit it.",
				],
				"choices": [{"text": "Safe roads, Bhadra.", "next": ""}],
			},
			"b_idle":
			{
				"text":
				[
					"Ask me about any road east of here. I have complained about all of them personally.",
					"Salt is cheap this year, which tells you the coast is calm. Everything is in the price of salt.",
					"My mule is called Patience. She is not.",
				],
				"choices":
				[
					{"text": "Tell me about the shrine again.", "condition": "flag:heard_of_shrine", "next": "b_lamp"},
					{"text": "Rest well.", "next": ""},
				],
			},
		},
	}


# ===========================================================================
#  Rishi Vamadeva — the hermit on the shrine knoll. Closes the errand.
# ===========================================================================
static func _hermit() -> Dictionary:
	return {
		"speaker": "Rishi Vamadeva",
		"entries":
		[
			{"node": "h_offer", "condition": ["quest:q_shrine:active", "item:lamp_oil"]},
			{"node": "h_waiting", "condition": "quest:q_shrine:active"},
			{"node": "h_lit", "condition": "flag:shrine_lit"},
			{"node": "h_intro", "condition": "!seen:h_intro"},
			{"node": "h_idle"},
		],
		"nodes":
		{
			"h_intro":
			{
				"text": "Careful of the last step. It is loose, and it has been loose since my teacher's time.",
				"choices":
				[
					{"text": "Do you live up here alone?", "next": "h_alone"},
					{
						"text": "The lamp at the threshold is out.",
						"condition": "flag:heard_of_shrine",
						"next": "h_lamp_talk"
					},
					{"text": "I will not disturb you.", "next": ""},
				],
			},
			"h_alone":
			{
				"text": "The hill is company. It says the same thing every morning, and it has never once been wrong.",
				"next": "h_hub",
			},
			"h_lamp_talk":
			{
				"text":
				"It is. My hands shake, and oil is dear. If ever you come by oil, climb up — I will find the flint.",
				"next": "h_hub",
			},
			"h_hub":
			{
				"text": ["Anything else, archer?", "Ask. The afternoon is long up here."],
				"choices":
				[
					{"text": "Do you live up here alone?", "next": "h_alone"},
					{"text": "What was this shrine?", "next": "h_shrine"},
					{"text": "Peace to you, rishi.", "next": ""},
				],
			},
			"h_shrine":
			{
				"text":
				"Older than the village. Older than the road that goes to the village. Somebody cut those steps for people they would never meet.",
				"next": "h_hub",
			},
			"h_offer":
			{
				"text": "You climbed. Most people look up at this hill and decide it is far enough.",
				"choices":
				[
					{"text": "Bhadra sent oil for the lamp.", "condition": "item:lamp_oil", "next": "h_light"},
					{"text": "Who are you?", "next": "h_who"},
				],
			},
			"h_who":
			{
				"text": "Vamadeva. I sweep these steps, and I am very bad at it.",
				"next": "h_offer",
			},
			"h_light":
			{
				"action":
				[
					"take:lamp_oil:1",
					"quest_advance:q_shrine:lamp:1",
					"quest_complete:q_shrine",
					"flag:shrine_lit=true",
					"sound:shrine_activate",
					"event:shrine_lit"
				],
				"text": "Then pour, and I will strike the flint. ...There. Look how far a small fire carries.",
				"next": "h_bless",
			},
			"h_bless":
			{
				"action": ["heal:35", "event:hermit_blessing"],
				"text":
				"Go with a steady hand. And do not sleep in the forest west of the ford — whatever walks "
						+ "there now, it did not walk there when I was young.",
				"next": "h_bless_2",
			},
			"h_bless_2":
			{
				"speaker": "Rama",
				"text": "I will remember it. Tell Bhadra his rice is paid.",
				"next": "",
			},
			"h_waiting":
			{
				"text":
				[
					"Come back with oil and we will have a flame by dark.",
					"An unlit lamp is only a stone with a hole in it. Bring oil.",
				],
				"choices": [{"text": "I will.", "next": ""}],
			},
			"h_lit":
			{
				"text":
				[
					"It has not gone out. I check it more often than is dignified.",
					"Two carts stopped below last night. They had not stopped here in years.",
				],
				"choices":
				[
					{"text": "What was this shrine?", "next": "h_shrine"},
					{"text": "Peace to you, rishi.", "next": ""},
				],
			},
			"h_idle":
			{
				"text":
				[
					"Sit as long as you like. The stone does not charge for it.",
					"Wind from the west today. It smells of the deep forest, and I do not care for it.",
				],
				"choices":
				[
					{"text": "What was this shrine?", "next": "h_shrine"},
					{"text": "Peace to you, rishi.", "next": ""},
				],
			},
		},
	}
