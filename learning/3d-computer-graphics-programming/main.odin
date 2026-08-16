package main

import "core:fmt"
import sdl "vendor:sdl2"

window: ^sdl.Window
renderer: ^sdl.Renderer

is_running: bool

initialise_window :: proc() -> bool {
	if sdl.Init(sdl.INIT_EVERYTHING) != 0 {
		fmt.println("Error initialising SDL.")
		return false
	}

	window = sdl.CreateWindow(
		"blockmon 3d",
		sdl.WINDOWPOS_CENTERED,
		sdl.WINDOWPOS_CENTERED,
		800,
		600,
		sdl.WINDOW_BORDERLESS,
	)

	if window == nil {
		fmt.println("Error creating SDL window.")
		return false
	}

	renderer = sdl.CreateRenderer(window, -1, sdl.RENDERER_SOFTWARE)
	if renderer == nil {
		fmt.println("Error creating SDL renderer")
		return false
	}

	return true
}

setup :: proc() {
	// TODO
}

process_input :: proc() {
	event: sdl.Event
	sdl.PollEvent(&event)

	#partial switch event.type {
	case sdl.EventType.QUIT:
		is_running = false

	case sdl.EventType.KEYDOWN:
		if (event.key.keysym.sym == sdl.Keycode.ESCAPE) {
			is_running = false
		}
	}
}

update :: proc() {
	// TODO
}

render :: proc() {
	sdl.SetRenderDrawColor(renderer, 255, 0, 0, 255)
	sdl.RenderClear(renderer)

	sdl.RenderPresent(renderer)
}

main :: proc() {
	is_running = initialise_window()
	if !is_running {
		return
	}

	setup()

	for is_running {
		process_input()
		update()
		render()
	}

	defer sdl.Quit()
}
