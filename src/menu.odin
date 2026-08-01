package main

import NS "core:sys/darwin/Foundation"

// karl2d's mac_init (platform_mac.odin) sets a main menu with only the app
// menu's Quit item — enough to quit, but macOS window shortcuts (Cmd+M,
// Cmd+W, the Window menu's tiling/resize items) are wired through menu key
// equivalents that don't exist without a File and Window menu. This adds
// them. Must run after karl2d has created the NSApplication and its menu bar.
setup_menu_bar :: proc() {
	app := NS.Application.sharedApplication()
	menu_bar := app->mainMenu()
	if menu_bar == nil {
		return
	}

	file_item := menu_bar->insertItemWithTitle(NS.AT("File"), nil, NS.AT(""), 1)
	file_menu := NS.Menu.alloc()->initWithTitle(NS.AT("File"))
	file_menu->addItemWithTitle(
		NS.AT("Close Window"),
		NS.sel_registerName(cstring("performClose:")),
		NS.AT("w"),
	)
	file_item->setSubmenu(file_menu)

	window_item := menu_bar->insertItemWithTitle(NS.AT("Window"), nil, NS.AT(""), 2)
	window_menu := NS.Menu.alloc()->initWithTitle(NS.AT("Window"))
	window_menu->addItemWithTitle(
		NS.AT("Minimize"),
		NS.sel_registerName(cstring("performMiniaturize:")),
		NS.AT("m"),
	)
	window_menu->addItemWithTitle(
		NS.AT("Zoom"),
		NS.sel_registerName(cstring("performZoom:")),
		NS.AT(""),
	)
	full_screen_item := window_menu->addItemWithTitle(
		NS.AT("Enter Full Screen"),
		NS.sel_registerName(cstring("toggleFullScreen:")),
		NS.AT("f"),
	)
	full_screen_item->setKeyEquivalentModifierMask({.Command, .Control})
	window_item->setSubmenu(window_menu)

	// Registering the Window menu with AppKit (rather than just parenting it
	// under the menu bar) is what makes it list open windows and, on modern
	// macOS, gain the standard tiling/resize shortcuts.
	app->setWindowsMenu(window_menu)
}
