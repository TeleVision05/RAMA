class_name BootWarmup
extends RefCounted
## How long the first look around takes behind the loading screen. Four headings, a few
## frames each: enough for the renderer to draw (and so compile) every material the
## spawn area shows, short enough that a player waits about a second for it.

const VIEWS := 4
const FRAMES_PER_VIEW := 6
